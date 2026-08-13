import XCTest
@testable import museterm

final class MCPTransportFramingTests: XCTestCase {
    func testMCPAnswersNewlineDelimitedJSON() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let raw = try runMCPRaw(
            scriptURL: fixture.scriptURL,
            home: fixture.root,
            input: newlineFramed(initializeMessage)
        )

        XCTAssertFalse(
            raw.contains("Content-Length"),
            "a newline-delimited client must not be answered with LSP framing"
        )
        let response = try firstNewlineFramedResponse(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "qterm")
    }

    func testMCPStillAnswersContentLengthFraming() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let raw = try runMCPRaw(
            scriptURL: fixture.scriptURL,
            home: fixture.root,
            input: contentLengthFramed(initializeMessage)
        )

        XCTAssertTrue(
            raw.hasPrefix("Content-Length:"),
            "a Content-Length client must keep getting Content-Length replies"
        )
        let response = try contentLengthResponse(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
    }

    func testMCPHandlesNonASCIIWithoutLocaleEnvironment() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var input = newlineFramed(initializeMessage)
        input += newlineFramed([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "list_tabs", "arguments": [:] as [String: Any]]
        ])

        // The spawn environment deliberately omits LANG, which is how MCP hosts launch us.
        let raw = try runMCPRaw(scriptURL: fixture.scriptURL, home: fixture.root, input: input)
        let responses = try newlineFramedResponses(raw)
        XCTAssertEqual(responses.count, 2, "expected replies to both initialize and tools/call")

        let result = try XCTUnwrap(responses[1]["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(
            text.contains(Self.nonASCIITabTitle),
            "non-ASCII tab titles must survive a locale-less spawn, got: \(text)"
        )
    }

    // MARK: - Helpers

    private static let nonASCIITabTitle = "生产服务器 · 巡检"

    private var initializeMessage: [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "framing-test", "version": "1.0"]
            ]
        ]
    }

    private func makeFixture() throws -> (root: URL, scriptURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qterm-framing-\(UUID().uuidString)", isDirectory: true)
        let tools = root.appendingPathComponent(
            "Library/Application Support/QTerm/Tools",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("qterm")
        try MuseTermCLIInstaller.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let state: [String: Any] = [
            "schemaVersion": 1,
            "app": "QTerm",
            "version": "test",
            "snapshotSequence": 7,
            "selectedTabID": "tab-1",
            "tabs": [[
                "id": "tab-1",
                "index": 1,
                "title": Self.nonASCIITabTitle,
                "currentDirectory": "/tmp/巡检",
                "isSelected": true,
                "state": "running",
                "screen": "",
                "history": "",
                "commandDiagnostics": ["schemaVersion": 1, "failedCommandCount": 0],
                "commandBlocks": []
            ]]
        ]
        try JSONSerialization.data(withJSONObject: state).write(
            to: tools.appendingPathComponent("state.json")
        )
        return (root, scriptURL)
    }

    private func newlineFramed(_ message: [String: Any]) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: message)
        return data + Data("\n".utf8)
    }

    private func contentLengthFramed(_ message: [String: Any]) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: message)
        return Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
    }

    private func runMCPRaw(scriptURL: URL, home: URL, input: Data) throws -> String {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [scriptURL.path, "mcp"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func newlineFramedResponses(_ raw: String) throws -> [[String: Any]] {
        try raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    "not JSON: \(line)"
                )
            }
    }

    private func firstNewlineFramedResponse(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(newlineFramedResponses(raw).first, "no response on stdout")
    }

    private func contentLengthResponse(_ raw: String) throws -> [String: Any] {
        let separator = "\r\n\r\n"
        let range = try XCTUnwrap(raw.range(of: separator), "no LSP header separator")
        let body = String(raw[range.upperBound...])
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
    }
}
