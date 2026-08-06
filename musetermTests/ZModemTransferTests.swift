import Foundation
import XCTest
@testable import museterm

final class ZModemTransferTests: XCTestCase {

    // MARK: - PendingZModemProbe

    func testProbeDetectsReadyMarkerSplitAcrossChunks() {
        let probe = PendingZModemProbe(
            kind: .upload,
            readyMarker: "__MARKER_READY__",
            missingMarker: "__MARKER_MISSING__",
            startLocalTransfer: { _ in }
        )

        XCTAssertNil(probe.acceptRemoteProbeData(Array("noise __MARKER_RE".utf8)))
        let result = probe.acceptRemoteProbeData(Array("ADY__**tail".utf8))

        guard case .ready(let initialRemoteBytes) = result else {
            XCTFail("expected .ready, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(initialRemoteBytes, Array("**tail".utf8))
    }

    func testProbeDetectsMissingMarker() {
        let probe = PendingZModemProbe(
            kind: .download,
            readyMarker: "__MARKER_READY__",
            missingMarker: "__MARKER_MISSING__",
            startLocalTransfer: { _ in }
        )

        let result = probe.acceptRemoteProbeData(Array("sh: sz: not found\n__MARKER_MISSING__\n".utf8))
        guard case .missing = result else {
            XCTFail("expected .missing, got \(String(describing: result))")
            return
        }
    }

    func testAutomaticUploadDetectorRecognizesBinaryRzHandshakeAcrossChunks() {
        let detector = AutomaticZModemUploadDetector()

        XCTAssertNil(detector.accept(Array("rz waiting to receive.**".utf8)))
        let result = detector.accept([0x18] + Array("B0100000023be50\r".utf8))

        XCTAssertEqual(result, [0x2A, 0x2A, 0x18] + Array("B0100000023be50\r".utf8))
    }

    func testAutomaticUploadDetectorIgnoresOrdinaryTerminalOutput() {
        let detector = AutomaticZModemUploadDetector()

        XCTAssertNil(detector.accept(Array("build **B02000000 completed\n".utf8)))
    }

    // MARK: - ZModemProgressParser

    func testProgressParserParsesPercentAndFileName() {
        let parser = ZModemProgressParser()
        // lrzsz 分次写 stderr：先文件名行，再滚动进度行。文件名在后续
        // 进度更新中要保持记忆。
        let nameProgress = parser.accept(stderrData: Data("Sending: build.tar.gz\n".utf8))
        XCTAssertEqual(nameProgress?.fileName, "build.tar.gz")

        let percentProgress = parser.accept(stderrData: Data(" 42% 1024 KB".utf8))
        XCTAssertEqual(percentProgress?.fileName, "build.tar.gz")
        XCTAssertEqual(percentProgress?.percent ?? 0, 0.42, accuracy: 0.001)
    }

    func testProgressParserParsesByteFraction() {
        let parser = ZModemProgressParser()
        let progress = parser.accept(stderrData: Data("Bytes received: 500/2000 BPS:9600".utf8))

        XCTAssertEqual(progress?.percent ?? 0, 0.25, accuracy: 0.001)
    }

    // MARK: - ZModemDownloadPlan

    func testDownloadPlanInfersBasenameAndMovesFile() throws {
        let destinationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZModemPlanTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destinationDir) }
        let destination = destinationDir.appendingPathComponent("saved.bin")

        let plan = try ZModemDownloadPlan(remotePath: "/var/log/output.bin", destinationFile: destination)
        defer { plan.cleanup() }
        XCTAssertEqual(plan.remoteBasename, "output.bin")

        let payload = Data("zmodem payload".utf8)
        try payload.write(to: plan.temporaryDirectory.appendingPathComponent("output.bin"))
        try plan.moveDownloadedFileToDestination()

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testDownloadPlanRejectsPathWithoutBasename() {
        XCTAssertThrowsError(
            try ZModemDownloadPlan(
                remotePath: "///",
                destinationFile: FileManager.default.temporaryDirectory.appendingPathComponent("x.bin")
            )
        )
    }

    // MARK: - ZModemBridgeProcess

    func testBridgeForwardsAllOutputIncludingTrailingBytesBeforeExit() throws {
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmodem-bridge-\(UUID().uuidString).bin")
        try payload.write(to: payloadURL)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let exitExpectation = expectation(description: "onExit")
        let lock = NSLock()
        var received = Data()
        var receivedCountAtExit = -1

        // `cat <file>` 模拟本地 lrzsz：进程退出前写出的最后一段 stdout
        // （对应真实场景的 ZFIN/OO 收尾帧）必须在 onExit 前全部经 onOutput
        // 送达，否则远端 shell 不会恢复。
        let bridge = try ZModemBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [payloadURL.path],
            currentDirectory: nil,
            onOutput: { bytes in
                lock.lock()
                received.append(contentsOf: bytes)
                lock.unlock()
            },
            onProgress: { _ in },
            onExit: { _, _ in
                lock.lock()
                receivedCountAtExit = received.count
                lock.unlock()
                exitExpectation.fulfill()
            }
        )
        _ = bridge

        wait(for: [exitExpectation], timeout: 10)
        lock.lock()
        let finalReceived = received
        let finalCountAtExit = receivedCountAtExit
        lock.unlock()
        XCTAssertEqual(finalReceived, payload)
        XCTAssertEqual(finalCountAtExit, payload.count)
    }

    func testBridgeIdleWatchdogCancelsStalledTransferAndNotifiesRemote() throws {
        let exitExpectation = expectation(description: "onExit")
        let lock = NSLock()
        var output = Data()
        var reportedReason: ZModemBridgeEndReason?

        // stdin 挂着不写、`cat` 无输出 → 空转，看门狗必须触发。
        let bridge = try ZModemBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            currentDirectory: nil,
            idleTimeout: 0.5,
            onOutput: { bytes in
                lock.lock()
                output.append(contentsOf: bytes)
                lock.unlock()
            },
            onProgress: { _ in },
            onExit: { _, reason in
                lock.lock()
                reportedReason = reason
                lock.unlock()
                exitExpectation.fulfill()
            }
        )

        wait(for: [exitExpectation], timeout: 10)
        XCTAssertEqual(bridge.endReason, .timedOut)
        lock.lock()
        let finalOutput = output
        let finalReason = reportedReason
        lock.unlock()
        XCTAssertEqual(finalReason, .timedOut)
        // 远端要收到 ZMODEM cancel 连发（CAN×8），否则远端 rz/sz 挂死。
        XCTAssertTrue(finalOutput.contains(0x18))
    }

    func testBridgeUserCancelTerminatesProcessAndReportsReason() throws {
        let exitExpectation = expectation(description: "onExit")
        let echoExpectation = expectation(description: "echo")
        let payload = Array("hello zmodem".utf8)
        let lock = NSLock()
        var output = Data()
        var reportedReason: ZModemBridgeEndReason?
        var didSignalEcho = false

        let bridge = try ZModemBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            currentDirectory: nil,
            idleTimeout: 30,
            onOutput: { bytes in
                lock.lock()
                output.append(contentsOf: bytes)
                let shouldSignal = output.count >= payload.count && !didSignalEcho
                if shouldSignal { didSignalEcho = true }
                lock.unlock()
                if shouldSignal { echoExpectation.fulfill() }
            },
            onProgress: { _ in },
            onExit: { _, reason in
                lock.lock()
                reportedReason = reason
                lock.unlock()
                exitExpectation.fulfill()
            }
        )

        bridge.acceptRemoteData(payload)
        wait(for: [echoExpectation], timeout: 10)

        bridge.cancel(reason: .userCancelled)
        wait(for: [exitExpectation], timeout: 10)
        lock.lock()
        let finalOutput = output
        let finalReason = reportedReason
        lock.unlock()
        XCTAssertEqual(finalReason, .userCancelled)
        XCTAssertEqual(Array(finalOutput.prefix(payload.count)), payload)
    }
}
