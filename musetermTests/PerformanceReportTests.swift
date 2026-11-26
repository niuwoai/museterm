import Foundation
import Testing
@testable import museterm

struct PerformanceReportTests {
    @Test func tracksSustainedCPUAfterGraceAndWeightsByElapsedTime() throws {
        var trigger = PerformanceCPUTrigger(startedAt: 0)
        #expect(trigger.observe(.init(uptime: 19, cpuSeconds: 0)) == nil)
        #expect(trigger.observe(.init(uptime: 20, cpuSeconds: 1)) == nil)
        #expect(trigger.observe(.init(uptime: 21, cpuSeconds: 3)) == nil)
        let observed = trigger.observe(.init(uptime: 23, cpuSeconds: 4))
        let episode = try #require(observed)
        #expect(episode.duration == 3)
        #expect(episode.peak == 200)
        #expect(episode.average == 100)
        for t in 24...28 {
            #expect(trigger.observe(.init(uptime: Double(t), cpuSeconds: Double(t) - 19)) == nil)
        }
        #expect(trigger.observe(.init(uptime: 623, cpuSeconds: 606)) == nil)
        #expect(trigger.observe(.init(uptime: 625, cpuSeconds: 608)) == nil)
        #expect(trigger.observe(.init(uptime: 626, cpuSeconds: 609)) != nil)
    }

    @Test func gapsMissingSamplesAndThresholdClearTheEpisode() {
        var trigger = PerformanceCPUTrigger(startedAt: 0)
        for sample in [(20.0, 0.0), (21, 0.3), (22, 1.3), (26, 10), (27, 11)] {
            #expect(trigger.observe(.init(uptime: sample.0, cpuSeconds: sample.1)) == nil)
        }
        #expect(trigger.observe(nil) == nil)
        #expect(trigger.observe(.init(uptime: 28, cpuSeconds: 12)) == nil)
        #expect(trigger.observe(.init(uptime: 30, cpuSeconds: 14)) == nil)
        #expect(trigger.observe(.init(uptime: 31, cpuSeconds: 15)) != nil)
    }

    @Test func boundsCaptureAttemptsInARollingDay() {
        var trigger = PerformanceCPUTrigger(startedAt: 0)
        var cpuSeconds = 0.0
        func attempt(startingAt time: Double) -> Bool {
            var detected = false
            for offset in 0...3 {
                cpuSeconds += 1
                let episode = trigger.observe(.init(uptime: time + Double(offset), cpuSeconds: cpuSeconds))
                detected = detected || episode != nil
            }
            return detected
        }
        for index in 0..<30 {
            #expect(attempt(startingAt: 20 + Double(index * 603)))
        }
        #expect(!attempt(startingAt: 20 + Double(30 * 603)))
        #expect(attempt(startingAt: 23 + 86_400))
    }

    @Test func reportsAreEnabledByDefaultAndSelectionPersists() throws {
        let suite = "museterm.performance-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalPreferences(defaults: defaults)
        #expect(preferences.performanceReportsEnabled)
        preferences.performanceReportsEnabled = false
        #expect(!TerminalPreferences(defaults: defaults).performanceReportsEnabled)
        preferences.performanceReportsEnabled = true
        #expect(TerminalPreferences(defaults: defaults).performanceReportsEnabled)
    }

    @Test func redactsPrivatePathsAndLabelsWhilePreservingTrustedSymbolsAndUUIDs() throws {
        let text = """
        Process:         private-parent
        Path:            /Users/private owner/project/MuseTerm
        Physical footprint:         928K
        Physical footprint (peak):  944K
        ----

        Call graph:
            86 Thread_45106520   DispatchQueue_1: private-queue
              86 start  (in dyld) + 6652  [0x187b40d7c]
                86 runLoop  (in Foundation) + 8  [0x177b40d08]
                86 redraw  (in MuseTerm) + 18 (private.swift:20) [0x10436c674]
                  82 exportHistory  (in MuseTerm) + 48  [0x10436c688]  /Users/private owner/[0x199bcf008]/Host.swift:1409
                    82 private_plugin_symbol  (in secret-addon) + 8  [0x199bcf008]  Plugin.swift:42
                  86 evil/path  (in dyld) + 5  [0x187b40d77]

        Total number in stack (recursive counted multiple, when >=5):

        Binary Images:
               0x10436c000 -        0x10436c757 +MuseTerm (1.0) <84EDE66A-D6E7-36ED-A512-3FDBDE7D9265> /Users/private owner/project/MuseTerm
               0x177b40000 -        0x177b4ffff  com.apple.Foundation (1.0) <49A46327-F2D0-48E0-B936-6C698352E536> /System/Library/Frameworks/Foundation.framework/Foundation
               0x187b0f000 -        0x187bcec83  dyld (1.0.0 - 27104) <D8104ED6-185E-3A2F-AD71-B91EDDBE2598> /usr/lib/dyld
               0x199bcf000 -        0x199c0da5b  secret-addon (1.0) <F2BCEB9A-0FEC-3C92-B6EA-8E37157050E8> /Volumes/secret/secret-addon
        """
        let clean = try #require(PerformanceStackRedactor.redact(
            text, executableURL: URL(fileURLWithPath: "/Users/private owner/project/MuseTerm")
        ))
        for kept in ["928K", "944K", "Thread_45106520", "start  (in dyld)", "redraw  (in MuseTerm)",
                     "runLoop  (in com.apple.Foundation)",
                     "exportHistory  (in MuseTerm)  [0x10436c688]",
                     "???  [0x199bcf008]", "84EDE66A-D6E7-36ED-A512-3FDBDE7D9265"] {
            #expect(clean.contains(kept))
        }
        for removed in ["private", "evil/path", "secret", "/Users/", "/usr/lib/", "/Volumes/", "F2BCEB9A"] {
            #expect(!clean.contains(removed))
        }
        #expect(PerformanceStackRedactor.redact("empty or unexpected sample format", executableURL: nil) == nil)
    }

    @Test func matchesRedactedApplicationImagePathsByTheirLiveLoadAddresses() throws {
        let text = """
        Call graph:
            86 Thread_1
              86 exportedBuffer  (in MuseTerm.debug.dylib) + 32  [0x10436c674]  TerminalHostView.swift:1409
                86 pluginEntry  (in MuseTerm.debug.dylib) + 8  [0x199bcf008]  Plugin.swift:42

        Binary Images:
        0x10436c000 - 0x10436c757 +MuseTerm.debug.dylib (0) <84EDE66A-D6E7-36ED-A512-3FDBDE7D9265> /tmp/*/MuseTerm.app/Contents/MacOS/MuseTerm.debug.dylib
        0x199bcf000 - 0x199c0da5b +MuseTerm.debug.dylib (0) <F2BCEB9A-0FEC-3C92-B6EA-8E37157050E8> /tmp/*/MuseTerm.app/Contents/MacOS/MuseTerm.debug.dylib
        """
        let executable = URL(fileURLWithPath: "/private/tmp/isolated/MuseTerm.app/Contents/MacOS/MuseTerm")
        let clean = try #require(PerformanceStackRedactor.redact(
            text, executableURL: executable, applicationImageAddresses: [0x10436c000]
        ))
        #expect(clean.contains("exportedBuffer  (in MuseTerm.debug.dylib)  [0x10436c674]"))
        #expect(clean.contains("84EDE66A-D6E7-36ED-A512-3FDBDE7D9265"))
        #expect(clean.contains("???  [0x199bcf008]"))
        for removed in ["F2BCEB9A-0FEC-3C92-B6EA-8E37157050E8", "pluginEntry", "TerminalHostView.swift", "Plugin.swift", "/tmp/", ":1409"] {
            #expect(!clean.contains(removed))
        }
    }

    @Test func preservesLaterThreadsInAReportLargerThanTheOldGraphLimit() throws {
        let text = longSample(frameCount: 6_000)
        let clean = try #require(PerformanceStackRedactor.redact(text, executableURL: nil))
        #expect(clean.utf8.count > 512 * 1024)
        #expect(clean.contains("endOfFirstThread"))
        #expect(clean.contains("Thread_2\n"))
        #expect(clean.contains("workerMain"))
        #expect(!clean.contains("Call graph truncated"))
        #expect(!clean.contains("private-queue"))
    }

    @Test func oversizedGraphKeepsEveryThreadAndMarksOmittedFrames() throws {
        let text = longSample(frameCount: 12_000)
        let clean = try #require(PerformanceStackRedactor.redact(text, executableURL: nil))
        #expect(clean.utf8.count <= 1024 * 1024)
        #expect(clean.contains("Call graph truncated"))
        #expect(clean.contains("Thread_1\n"))
        #expect(clean.contains("mainThreadEntry"))
        #expect(!clean.contains("endOfFirstThread"))
        #expect(clean.contains("Thread_2\n"))
        #expect(clean.contains("workerMain"))
        #expect(clean.contains("workerLeaf"))
        #expect(clean.contains("D8104ED6-185E-3A2F-AD71-B91EDDBE2598"))
    }

    private func longSample(frameCount: Int) -> String {
        let largeSymbol = "longSymbol" + String(repeating: "X", count: 90)
        let frames = String(repeating: "    +   1 \(largeSymbol)  (in dyld) + 4 [0x187b40d7c]\n", count: frameCount)
        return "Call graph:\n    1 Thread_1   DispatchQueue_1: private-queue\n"
            + "    + 1 mainThreadEntry  (in dyld) + 4 [0x187b40d7c]\n" + frames
            + "    +   1 endOfFirstThread  (in dyld) + 4 [0x187b40d7c]\n\n"
            + "    1 Thread_2\n    + 1 workerMain  (in dyld) + 4 [0x187b40d7c]\n"
            + "    +   1 workerLeaf  (in dyld) + 4 [0x187b40d7c]\n\n"
            + "Total number in stack (recursive counted multiple, when >=5):\n\nBinary Images:\n"
            + "0x187b0f000 - 0x187bcec83  dyld (1.0) <D8104ED6-185E-3A2F-AD71-B91EDDBE2598> /usr/lib/dyld\n"
    }

    @Test(.timeLimit(.minutes(1))) func capturesAndRedactsARealMacOSSample() async throws {
        let target = Process()
        let executable = URL(fileURLWithPath: "/bin/sleep")
        target.executableURL = executable
        target.arguments = ["30"]
        try target.run()
        defer { if target.isRunning { target.terminate(); target.waitUntilExit() } }
        let capture = try await PerformanceStackCapture.capture(pid: target.processIdentifier, executableURL: executable)
        let stacks = try #require(capture)
        #expect(stacks.contains("Call graph:"))
        #expect(stacks.contains("Binary Images:"))
        #expect(stacks.contains("(in "))
        #expect(!stacks.contains("/bin/sleep"))
    }

    @Test func sendsAnonymousRequestMatchingSomeIMContractAndChecksReceipt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractURLProtocol.self]
        let client = PerformanceReportClient(session: URLSession(configuration: config))
        let installID = UUID()
        let report = PerformanceReport(installID: installID, capturedAt: Date(), surface: .background,
                                       episode: .init(duration: 3, peak: 120, average: 76), stacks: "Call graph: test")
        try await client.upload(report)
        try await client.delete(installID: installID)
        let invalid = PerformanceReport(installID: installID, capturedAt: Date(), surface: .foreground,
                                        episode: .init(duration: 3, peak: 120, average: 76), stacks: "Call graph: test")
        await #expect(throws: PerformanceReportClient.Failure.invalidReceipt) { try await client.upload(invalid) }
    }
}

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try reply()
            let status = request.url?.path.hasSuffix("/forget") == true ? 200 : 202
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func reply() throws -> Data {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try JSONSerialization.jsonObject(with: bodyData())
        let json = try #require(body as? [String: Any])
        let installID = try #require(json["install_id"] as? String)
        #expect(UUID(uuidString: installID) != nil)
        switch request.url?.absoluteString {
        case "https://og.niuwoai.com/api/v1/public/telemetry/forget":
            #expect(Set(json.keys) == ["install_id"])
            return Data(#"{"code":0,"data":{"deleted":1}}"#.utf8)
        case "https://og.niuwoai.com/api/v1/public/telemetry/perf-reports":
            let required: Set<String> = ["report_id", "install_id", "app_id", "app_version", "os_version", "arch",
                                         "captured_at", "active_surface", "threshold_percent", "sustained_seconds",
                                         "peak_cpu_percent", "average_cpu_percent", "sample_duration_seconds",
                                         "call_stacks_format", "call_stacks"]
            #expect(required.isSubset(of: Set(json.keys)))
            #expect(Set(json.keys).isSubset(of: required.union(["build", "locale"])))
            #expect(json["app_id"] as? String == "museterm")
            #expect(json["call_stacks_format"] as? String == "macos-sample-v1")
            let capturedAt = try #require(json["captured_at"] as? String)
            #expect(ISO8601DateFormatter().date(from: capturedAt) != nil)
            let reportID = try #require(json["report_id"] as? String)
            #expect(UUID(uuidString: reportID) != nil)
            let receiptID = json["active_surface"] as? String == "museterm.background" ? reportID : "wrong-id"
            return try JSONSerialization.data(withJSONObject: ["code": 0, "accepted": true, "report_id": receiptID])
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func bodyData() throws -> Data {
        if let bytes = request.httpBody { return bytes }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = Array(repeating: UInt8(0), count: 4_096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count == 0 { return data }
            guard count > 0 else { throw URLError(.cannotDecodeRawData) }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
