import Darwin
import XCTest
@testable import museterm

@MainActor
final class TerminalWaitMCPTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let process: Process
        let input: Pipe
        let output: Pipe
        var requests: URL { root.appendingPathComponent("Library/Application Support/QTerm/Tools/requests") }
        var responses: URL { root.appendingPathComponent("Library/Application Support/QTerm/Tools/responses") }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-wait-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("qterm.rb")
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        try (definitions + "\ndef access_token; nil; end\ncommand_mcp\n").write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return Fixture(root: root, process: process, input: input, output: output)
    }

    private func send(_ payload: [String: Any], to fixture: Fixture) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(10)
        try fixture.input.fileHandleForWriting.write(contentsOf: data)
    }

    private func response(_ fixture: Fixture) throws -> [String: Any] {
        var descriptor = pollfd(fd: fixture.output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5_000) > 0 else { throw NSError(domain: "MCP response timeout", code: 1) }
        var data = Data()
        while let byte = try fixture.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            data.append(byte)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitRequest(_ fixture: Fixture, action: String) throws -> [String: Any] {
        let end = Date().addingTimeInterval(5)
        repeat {
            let files = (try? FileManager.default.contentsOfDirectory(at: fixture.requests, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], request["action"] as? String == action { return request }
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < end
        throw NSError(domain: "App request timeout: \(action)", code: 1)
    }

    private func answer(_ fixture: Fixture, request: [String: Any]) throws {
        let id = try XCTUnwrap(request["id"] as? String)
        try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "snapshotSequence": 1])
            .write(to: fixture.responses.appendingPathComponent("\(id).json"), options: .atomic)
        try FileManager.default.removeItem(at: fixture.requests.appendingPathComponent("\(id).json"))
    }

    private func beginWait(_ fixture: Fixture) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "wait_session", "arguments": ["spec": ["condition": "events", "after": ["appEpoch": UUID().uuidString, "sequence": 0], "timeoutSeconds": 30]]]], to: fixture)
        return try waitRequest(fixture, action: "wait_session")
    }

    private func cleanup(_ fixture: Fixture) {
        if fixture.process.isRunning { fixture.process.terminate() }
        try? fixture.input.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testPendingWaitDoesNotBlockRenewReleaseOrCancellation() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let pending = try beginWait(fixture)
        let tab = UUID().uuidString
        for (id, name) in [(2, "renew_tab_control"), (3, "release_tab")] {
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": ["tab": tab]]], to: fixture)
            let request = try waitRequest(fixture, action: name)
            try answer(fixture, request: request)
            XCTAssertEqual(try response(fixture)["id"] as? Int, id)
        }
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]], to: fixture)
        try send(["jsonrpc": "2.0", "id": 4, "method": "ping"], to: fixture)
        XCTAssertEqual(try response(fixture)["id"] as? Int, 4)
        let cancellation = try waitRequest(fixture, action: "cancel_wait")
        XCTAssertEqual(cancellation["waitID"] as? String, pending["id"] as? String)
        XCTAssertEqual(cancellation["controlID"] as? String, pending["controlID"] as? String)
        XCTAssertEqual(cancellation["noResponse"] as? Bool, true)
        try fixture.input.fileHandleForWriting.close()
        let remaining = fixture.output.fileHandleForReading.readDataToEndOfFile()
        fixture.process.waitUntilExit()
        XCTAssertTrue(remaining.isEmpty, "cancelled MCP requests must not emit a response")
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }

    func testEOFAbandonsPendingWaitAndDoesNotWaitForServerTimeout() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        _ = try beginWait(fixture)
        try fixture.input.fileHandleForWriting.close()
        _ = try waitRequest(fixture, action: "cancel_wait")
        let remaining = fixture.output.fileHandleForReading.readDataToEndOfFile()
        fixture.process.waitUntilExit()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }

    func testCompletedWaitAndPingFramesDoNotInterleave() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let wait = try beginWait(fixture)
        try send(["jsonrpc": "2.0", "id": 2, "method": "ping"], to: fixture)
        XCTAssertEqual(try response(fixture)["id"] as? Int, 2)
        try answer(fixture, request: wait)
        let completed = try response(fixture)
        XCTAssertEqual(completed["id"] as? Int, 1)
        XCTAssertNil(completed["error"])
        try fixture.input.fileHandleForWriting.close()
        fixture.process.waitUntilExit()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }
}
