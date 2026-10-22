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

    func testMCPHelpExplainsLeaseLifecycleAndListsControlTools() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let input = newlineFramed([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "help", "arguments": [:] as [String: Any]]
        ])
        let raw = try runMCPRaw(scriptURL: fixture.scriptURL, home: fixture.root, input: input)
        let response = try firstNewlineFramedResponse(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let help = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(help["version"] as? String, AppVersion.value)
        let tools = try XCTUnwrap(help["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        for name in ["help", "takeover_tab", "renew_tab_control", "release_tab"] {
            XCTAssertTrue(names.contains(name))
        }
        XCTAssertTrue(text.contains("120 seconds"))
        XCTAssertTrue(text.contains("Human unlock"))
        XCTAssertTrue(text.contains("does not select"))
    }

    func testMCPKeepsOwnerIdentityAndReleasesOnEOF() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tabID = UUID().uuidString
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [fixture.scriptURL.path, "mcp"]
        process.environment = ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for (index, name) in ["takeover_tab", "renew_tab_control", "send_text"].enumerated() {
            input.fileHandleForWriting.write(newlineFramed([
                "jsonrpc": "2.0", "id": index + 1, "method": "tools/call",
                "params": ["name": name, "arguments": ["tab": tabID, "text": "pwd\r"]]
            ]))
        }
        try input.fileHandleForWriting.close()
        let root = fixture.root.appendingPathComponent("Library/Application Support/QTerm/Tools")
        let requests = root.appendingPathComponent("requests")
        let responses = root.appendingPathComponent("responses")
        var actions: [String] = []
        var owners = Set<String>()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: requests,
                includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                actions.append(try XCTUnwrap(request["action"] as? String))
                owners.insert(try XCTUnwrap(request["controlID"] as? String))
                let id = try XCTUnwrap(request["id"] as? String)
                try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "tabID": tabID])
                    .write(to: responses.appendingPathComponent("\(id).json"), options: .atomic)
                try FileManager.default.removeItem(at: file)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(actions, ["takeover_tab", "renew_tab_control", "input", "release_tab"])
        XCTAssertEqual(owners.count, 1)
        XCTAssertNotNil(owners.first.flatMap(UUID.init(uuidString:)))
        if !process.isRunning {
            let raw = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let replies = try newlineFramedResponses(raw)
            XCTAssertEqual(replies.count, 3)
            XCTAssertTrue(replies.allSatisfy { $0["error"] == nil })
        }
    }

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
