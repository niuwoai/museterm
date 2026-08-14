import Darwin
import Foundation
import Network
import XCTest
@testable import museterm

private final class SessionTunnelTestOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var matchedMarkers: Set<String> = []

    func append(_ bytes: Data, detecting marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data.append(bytes)
        guard !matchedMarkers.contains(marker),
              String(decoding: data, as: UTF8.self).contains(marker) else {
            return false
        }
        matchedMarkers.insert(marker)
        return true
    }

    func append(_ bytes: Data, detecting markers: [String]) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        data.append(bytes)
        let text = String(decoding: data, as: UTF8.self)
        var matches = Set<String>()
        for marker in markers where !matchedMarkers.contains(marker) && text.contains(marker) {
            matchedMarkers.insert(marker)
            matches.insert(marker)
        }
        return matches
    }

    func append(_ bytes: Data) {
        lock.lock()
        data.append(bytes)
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class SessionTunnelTests: XCTestCase {
    private static let canonicalPTYInputByteLimit = 1_024

    func testHelperPlatformDetectionAndResourceNames() {
        let cases: [(String, String, SessionTunnelHelperPlatform)] = [
            ("Linux", "x86_64", .linuxAMD64),
            ("linux", "aarch64", .linuxARM64),
            ("Darwin", "x86_64", .darwinAMD64),
            ("darwin", "arm64", .darwinARM64)
        ]

        for (operatingSystem, architecture, expected) in cases {
            XCTAssertEqual(
                SessionTunnelHelperPlatform.detect(
                    operatingSystem: operatingSystem,
                    architecture: architecture
                ),
                expected
            )
            XCTAssertEqual(expected.resourceName, "museterm-tunnel-\(expected.rawValue)")
        }
        XCTAssertNil(
            SessionTunnelHelperPlatform.detect(
                operatingSystem: "FreeBSD",
                architecture: "amd64"
            )
        )
    }

    func testAllStaticHelpersAreBundled() {
        for platform in SessionTunnelHelperPlatform.allCases {
            let payload = SessionTunnelBundledHelper.data(for: platform)
            XCTAssertNotNil(payload, platform.rawValue)
            XCTAssertGreaterThan(payload?.count ?? 0, 1_000_000, platform.rawValue)
        }
    }

    func testPlatformProbeProducesProtocolFrame() throws {
        let token = "platformprobe"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f",
            "-c",
            SessionTunnelBundledHelper.platformProbeCommand(token: token)
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(output.fileHandleForReading.readDataToEndOfFile()))
        let platform = try XCTUnwrap(messages.first { $0.type == "platform" })
        XCTAssertEqual(platform.token, token)
#if arch(arm64)
        let expectedPlatform = SessionTunnelHelperPlatform.darwinARM64
#else
        let expectedPlatform = SessionTunnelHelperPlatform.darwinAMD64
#endif
        XCTAssertEqual(
            SessionTunnelHelperPlatform.detect(probeData: try XCTUnwrap(platform.data)),
            expectedPlatform
        )
    }

    func testConfigurationValidationNormalizesValuesAndRendersIPv6() throws {
        let configuration = try SessionTunnelConfiguration(
            name: "  database  ",
            targetHost: "  fd00::12  ",
            targetPort: 3306,
            localPort: 13306
        ).validated()

        XCTAssertEqual(configuration.name, "database")
        XCTAssertEqual(configuration.targetHost, "fd00::12")
        XCTAssertEqual(configuration.localEndpoint, "127.0.0.1:13306")
        XCTAssertEqual(configuration.remoteEndpoint, "[fd00::12]:3306")
    }

    func testConfigurationRejectsMissingHostAndInvalidPorts() {
        XCTAssertThrowsError(
            try SessionTunnelConfiguration(
                name: "",
                targetHost: " ",
                targetPort: 3306,
                localPort: 13306
            ).validated()
        ) { error in
            XCTAssertEqual(error as? SessionTunnelConfigurationError, .missingTargetHost)
        }

        XCTAssertThrowsError(
            try SessionTunnelConfiguration(
                name: "",
                targetHost: "db.internal",
                targetPort: 0,
                localPort: 70_000
            ).validated()
        ) { error in
            XCTAssertEqual(error as? SessionTunnelConfigurationError, .invalidTargetPort)
        }
    }

    func testFrameDecoderHandlesFragmentedFramesAndIgnoresTerminalNoise() throws {
        let first = SessionTunnelProtocolMessage(
            token: "token",
            type: "ready"
        )
        let second = SessionTunnelProtocolMessage(
            token: "token",
            type: "data",
            channel: 7,
            data: Data("hello".utf8).base64EncodedString()
        )
        let firstBytes = try XCTUnwrap(SessionTunnelFrameCodec.encode(first))
        let secondBytes = try XCTUnwrap(SessionTunnelFrameCodec.encode(second))
        let splitIndex = firstBytes.count / 2
        var decoder = SessionTunnelFrameCodec.Decoder()

        XCTAssertTrue(decoder.append(Array("shell prompt\n".utf8)).isEmpty)
        XCTAssertTrue(decoder.append(Array(firstBytes[..<splitIndex])).isEmpty)
        let decoded = decoder.append(
            Array(firstBytes[splitIndex...]) + secondBytes
        )

        XCTAssertEqual(decoded, [first, second])
    }

    func testRemoteHelperStartsAndStopsOverPipes() throws {
        let token = "integrationtoken"
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            "-c",
            SessionTunnelRemoteHelper.pythonSource,
            "127.0.0.1",
            "9",
            token
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let shutdown = SessionTunnelProtocolMessage(token: token, type: "shutdown")
        input.fileHandleForWriting.write(
            Data(try XCTUnwrap(SessionTunnelFrameCodec.encode(shutdown)))
        )
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(outputData))

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(messages.map(\.type), ["ready", "stopped"])
        XCTAssertTrue(messages.allSatisfy { $0.token == token })
    }

    func testBootstrapCommandShellQuotesTargetAndUsesEphemeralPythonHelper() {
        let command = SessionTunnelRemoteHelper.bootstrapCommand(
            configuration: SessionTunnelConfiguration(
                name: "db",
                targetHost: "db'host",
                targetPort: 3306,
                localPort: 13306
            ),
            token: "abc123"
        )

        XCTAssertTrue(command.contains("command -v python3"))
        XCTAssertTrue(command.hasPrefix("/bin/sh -c "))
        XCTAssertTrue(command.contains("python3 -c"))
        XCTAssertTrue(command.contains("db"))
        XCTAssertTrue(command.contains("host"))
        XCTAssertTrue(command.contains("abc123"))
        XCTAssertFalse(command.contains("__MUSETERM_TUNNEL_PYTHON_MISSING__abc123"))
        XCTAssertLessThan(command.utf8.count, 1_000)
        XCTAssertTrue(command.hasSuffix("\n"))
    }

    func testBootstrapCommandRunsFromFish() throws {
        let fishURL = URL(fileURLWithPath: "/opt/homebrew/bin/fish")
        guard FileManager.default.isExecutableFile(atPath: fishURL.path) else {
            throw XCTSkip("fish is not installed")
        }

        let token = "fishbootstrap"
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = fishURL
        process.arguments = [
            "-c",
            SessionTunnelRemoteHelper.bootstrapCommand(
                configuration: SessionTunnelConfiguration(
                    name: "db",
                    targetHost: "127.0.0.1",
                    targetPort: 9,
                    localPort: 13306
                ),
                token: token
            )
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        input.fileHandleForWriting.write(Data(SessionTunnelRemoteHelper.helperPayload()))
        let shutdown = SessionTunnelProtocolMessage(token: token, type: "shutdown")
        input.fileHandleForWriting.write(
            Data(try XCTUnwrap(SessionTunnelFrameCodec.encode(shutdown)))
        )
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(outputData))
        XCTAssertEqual(
            messages.map(\.type),
            ["loader_ready", "ready", "stopped"],
            String(decoding: outputData, as: UTF8.self)
        )
    }

    func testBootstrapCommandRunsThroughInteractivePTY() throws {
        let token = "ptybootstrap"
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-f"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let loaderReady = expectation(description: "PTY loader is ready")
        let outputBuffer = SessionTunnelTestOutputBuffer()
        let loaderReadyMarker = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"loader_ready\"}"
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if outputBuffer.append(data, detecting: loaderReadyMarker) {
                loaderReady.fulfill()
            }
        }
        let terminated = expectation(description: "interactive PTY exited")
        process.terminationHandler = { _ in
            terminated.fulfill()
        }

        try process.run()
        input.fileHandleForWriting.write(
            Data(
                SessionTunnelRemoteHelper.bootstrapInputBytes(
                    configuration: SessionTunnelConfiguration(
                        name: "db",
                        targetHost: "127.0.0.1",
                        targetPort: 9,
                        localPort: 13306
                    ),
                    token: token
                )
            )
        )
        let loaderResult = XCTWaiter.wait(for: [loaderReady], timeout: 5)
        guard loaderResult == .completed else {
            process.terminate()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            XCTFail("PTY loader did not become ready: \(String(decoding: outputBuffer.snapshot, as: UTF8.self))")
            return
        }
        input.fileHandleForWriting.write(Data(SessionTunnelRemoteHelper.helperPayload()))
        let shutdown = SessionTunnelProtocolMessage(token: token, type: "shutdown")
        input.fileHandleForWriting.write(
            Data(try XCTUnwrap(SessionTunnelFrameCodec.encode(shutdown)))
        )
        input.fileHandleForWriting.write(Data("exit\r".utf8))
        input.fileHandleForWriting.closeFile()
        let waitResult = XCTWaiter.wait(for: [terminated], timeout: 5)
        if waitResult == .timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        output.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
        let outputData = outputBuffer.snapshot
        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(outputData))
        XCTAssertEqual(
            messages.map(\.type),
            ["loader_ready", "ready", "stopped"],
            String(decoding: outputData, as: UTF8.self)
        )
    }

    func testStaticLoaderUploadsRunsAndCleansUpThroughInteractivePTY() throws {
        let token = "staticptybootstrap"
        let payload = Data(
            """
            #!/bin/sh
            _mst_token="$3"
            printf '\\n{"v":1,"token":"%s","type":"ready"}\\n' "$_mst_token"
            while IFS= read -r _mst_line; do
              case "$_mst_line" in
                *'"type":"shutdown"'*) break ;;
              esac
            done
            printf '{"v":1,"token":"%s","type":"stopped"}\\n' "$_mst_token"
            exit 0
            """.utf8
        )
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-f"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let loaderReady = expectation(description: "static loader is ready")
        let helperReady = expectation(description: "static helper is ready")
        let shellReady = expectation(description: "shell was restored")
        let terminated = expectation(description: "interactive PTY exited")
        let outputBuffer = SessionTunnelTestOutputBuffer()
        let loaderMarker = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"loader_ready\"}"
        let helperMarker = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"ready\"}"
        let shellMarker = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"shell_ready\",\"data\":\"0\"}"
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let matches = outputBuffer.append(
                data,
                detecting: [loaderMarker, helperMarker, shellMarker]
            )
            if matches.contains(loaderMarker) {
                loaderReady.fulfill()
            }
            if matches.contains(helperMarker) {
                helperReady.fulfill()
            }
            if matches.contains(shellMarker) {
                shellReady.fulfill()
            }
        }
        process.terminationHandler = { _ in terminated.fulfill() }

        try process.run()
        let encodedPayload = SessionTunnelBundledHelper.helperPayload(payload)
        let loaderInput = SessionTunnelBundledHelper.loaderInputBytes(
            configuration: SessionTunnelConfiguration(
                name: "db",
                targetHost: "127.0.0.1",
                targetPort: 9,
                localPort: 13306
            ),
            token: token,
            payloadByteCount: encodedPayload.count
        )
        XCTAssertLessThan(loaderInput.count, Self.canonicalPTYInputByteLimit)
        input.fileHandleForWriting.write(Data(loaderInput))
        guard XCTWaiter.wait(for: [loaderReady], timeout: 5) == .completed else {
            process.terminate()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            XCTFail(
                "static loader did not become ready: "
                    + String(decoding: outputBuffer.snapshot, as: UTF8.self)
            )
            return
        }
        input.fileHandleForWriting.write(
            Data(encodedPayload)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [helperReady], timeout: 45), .completed)
        input.fileHandleForWriting.write(
            Data(
                try XCTUnwrap(
                    SessionTunnelFrameCodec.encode(
                        SessionTunnelProtocolMessage(token: token, type: "shutdown")
                    )
                )
            )
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shellReady], timeout: 45), .completed)
        input.fileHandleForWriting.write(Data("exit\r".utf8))
        input.fileHandleForWriting.closeFile()
        let waitResult = XCTWaiter.wait(for: [terminated], timeout: 5)
        if waitResult == .timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        output.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(outputBuffer.snapshot))
        XCTAssertEqual(
            messages.map(\.type),
            ["loader_ready", "ready", "stopped", "shell_ready"]
        )
    }

    func testStaticLoaderCommandsFitCanonicalPTYInputLimit() {
        let configuration = SessionTunnelConfiguration(
            name: "db",
            targetHost: String(repeating: "a", count: 253),
            targetPort: 65_535,
            localPort: 65_535
        )
        let token = String(repeating: "f", count: 32)

        for isGzipCompressed in [false, true] {
            let loaderInput = SessionTunnelBundledHelper.loaderInputBytes(
                configuration: configuration,
                token: token,
                payloadByteCount: 9_999_999,
                isGzipCompressed: isGzipCompressed
            )
            XCTAssertLessThan(
                loaderInput.count,
                Self.canonicalPTYInputByteLimit,
                "gzip=\(isGzipCompressed), bytes=\(loaderInput.count)"
            )
        }
    }

    func testNativeStaticHelperStartsAndStopsOverPipes() throws {
        let token = "nativestatictoken"
#if arch(arm64)
        let platform = SessionTunnelHelperPlatform.darwinARM64
#else
        let platform = SessionTunnelHelperPlatform.darwinAMD64
#endif
        let payload = try XCTUnwrap(SessionTunnelBundledHelper.data(for: platform))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-static-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let helperURL = temporaryDirectory.appendingPathComponent("museterm-tunnel")
        try payload.write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = ["127.0.0.1", "9", token]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let shutdown = SessionTunnelProtocolMessage(token: token, type: "shutdown")
        input.fileHandleForWriting.write(
            Data(try XCTUnwrap(SessionTunnelFrameCodec.encode(shutdown)))
        )
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        var decoder = SessionTunnelFrameCodec.Decoder()
        let messages = decoder.append(Array(outputData))
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(messages.map(\.type), ["ready", "stopped"])
        XCTAssertTrue(messages.allSatisfy { $0.token == token })
    }

    func testBridgeSelectsStaticPayloadAfterPlatformProbe() throws {
        let token = "bridgeplatform"
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let selectedLoader = expectation(description: "selected static loader")
        let uploadedPayload = expectation(description: "uploaded static payload")
        let finished = expectation(description: "bridge finished")
        let bridge = SessionTunnelBridge(
            configuration: SessionTunnelConfiguration(
                name: "db",
                targetHost: "db.internal",
                targetPort: 3306,
                localPort: 13306
            ),
            token: token,
            bundledHelperArtifact: { platform in
                XCTAssertEqual(platform, .linuxARM64)
                return SessionTunnelBundledHelper.Artifact(
                    data: payload,
                    isGzipCompressed: false
                )
            },
            sendToRemote: { bytes in
                let text = String(decoding: bytes, as: UTF8.self)
                if text.contains("loader_ready"), text.contains("mktemp") {
                    selectedLoader.fulfill()
                }
                if bytes == SessionTunnelBundledHelper.helperPayload(payload) {
                    uploadedPayload.fulfill()
                }
            },
            onStatus: { _ in },
            onFinished: { error in
                XCTAssertNil(error)
                finished.fulfill()
            }
        )

        bridge.start()
        bridge.acceptRemoteData(
            try XCTUnwrap(
                SessionTunnelFrameCodec.encode(
                    SessionTunnelProtocolMessage(
                        token: token,
                        type: "platform",
                        data: "Linux|aarch64"
                    )
                )
            )
        )
        wait(for: [selectedLoader], timeout: 2)
        bridge.acceptRemoteData(
            try XCTUnwrap(
                SessionTunnelFrameCodec.encode(
                    SessionTunnelProtocolMessage(token: token, type: "loader_ready")
                )
            )
        )
        wait(for: [uploadedPayload], timeout: 2)
        bridge.forceCancel(error: nil)
        wait(for: [finished], timeout: 2)
    }

    func testBridgeForwardsTCPThroughRemoteHelper() throws {
        let networkQueue = DispatchQueue(label: "im.some.museterm.session-tunnel-tests")
        let targetReady = expectation(description: "Echo target is ready")
        let targetListener = try NWListener(using: .tcp, on: .any)
        targetListener.stateUpdateHandler = { state in
            if case .ready = state { targetReady.fulfill() }
        }
        targetListener.newConnectionHandler = { connection in
            connection.start(queue: networkQueue)
            Self.echo(on: connection)
        }
        targetListener.start(queue: networkQueue)
        wait(for: [targetReady], timeout: 3)
        let targetPort = try XCTUnwrap(targetListener.port?.rawValue)

        let localPort = try Self.unusedLoopbackPort()

        let token = "forwardingtoken"
        let helper = Process()
        let helperInput = Pipe()
        let helperOutput = Pipe()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        helper.arguments = [
            "python3",
            "-c",
            SessionTunnelRemoteHelper.pythonSource,
            "127.0.0.1",
            String(targetPort),
            token
        ]
        helper.standardInput = helperInput
        helper.standardOutput = helperOutput
        helper.standardError = helperOutput

        let running = expectation(description: "Tunnel is running")
        let finished = expectation(description: "Tunnel is stopped")
        var didFulfillRunning = false
        var bridge: SessionTunnelBridge!
        bridge = SessionTunnelBridge(
            configuration: SessionTunnelConfiguration(
                name: "Echo",
                targetHost: "127.0.0.1",
                targetPort: Int(targetPort),
                localPort: Int(localPort)
            ),
            token: token,
            shouldSendBootstrapCommand: false,
            sendToRemote: { bytes in
                helperInput.fileHandleForWriting.write(Data(bytes))
            },
            onStatus: { status in
                if status.phase == .running, !didFulfillRunning {
                    didFulfillRunning = true
                    running.fulfill()
                }
            },
            onFinished: { error in
                XCTAssertNil(error)
                finished.fulfill()
            }
        )
        helperOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            bridge.acceptRemoteData(Array(data))
        }

        try helper.run()
        bridge.start()
        wait(for: [running], timeout: 5)

        let responseReceived = expectation(description: "Echo response crosses the tunnel")
        let client = NWConnection(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: localPort)),
            using: .tcp
        )
        let payload = Data("museterm-session-tunnel".utf8)
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: payload, completion: .contentProcessed { error in
                XCTAssertNil(error)
                client.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) {
                    data, _, _, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(data, payload)
                    responseReceived.fulfill()
                }
            })
        }
        client.start(queue: networkQueue)
        wait(for: [responseReceived], timeout: 5)

        client.cancel()
        bridge.stop()
        wait(for: [finished], timeout: 5)
        helperOutput.fileHandleForReading.readabilityHandler = nil
        if helper.isRunning { helper.terminate() }
        helper.waitUntilExit()
        targetListener.cancel()
    }

    private static func echo(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            data, _, isComplete, error in
            guard let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { sendError in
                if isComplete || sendError != nil {
                    connection.cancel()
                } else {
                    echo(on: connection)
                }
            })
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) throws {
        let chunkSize = 65_536
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            handle.write(data[offset..<end])
            offset = end
        }
    }

    private static func unusedLoopbackPort() throws -> UInt16 {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
