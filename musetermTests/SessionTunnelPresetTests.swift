import Foundation
import XCTest
@testable import museterm

final class SessionTunnelPresetTests: XCTestCase {
    func testStoreDeduplicatesConfigurationsAndTracksUsage() throws {
        let suiteName = "SessionTunnelPresetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = SessionTunnelConfiguration(
            name: "  MySQL  ",
            targetHost: "  127.0.0.1 ",
            targetPort: 3306,
            localPort: 13306
        )

        _ = SessionTunnelPresetStore.record(
            configuration,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 100)
        )
        let presets = SessionTunnelPresetStore.record(
            configuration,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "MySQL")
        XCTAssertEqual(presets[0].targetHost, "127.0.0.1")
        XCTAssertEqual(presets[0].targetPort, 3306)
        XCTAssertEqual(presets[0].localPort, 13306)
        XCTAssertEqual(presets[0].useCount, 2)
        XCTAssertEqual(presets[0].lastUsedAt, Date(timeIntervalSince1970: 200))
    }

    func testStoreKeepsOnlyMostRecentPresets() throws {
        let suiteName = "SessionTunnelPresetLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for offset in 0..<(SessionTunnelPresetStore.maximumPresetCount + 3) {
            SessionTunnelPresetStore.record(
                SessionTunnelConfiguration(
                    name: "Service \(offset)",
                    targetHost: "127.0.0.1",
                    targetPort: 3_000 + offset,
                    localPort: 13_000 + offset
                ),
                defaults: defaults,
                now: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }

        let presets = SessionTunnelPresetStore.load(defaults: defaults)
        XCTAssertEqual(presets.count, SessionTunnelPresetStore.maximumPresetCount)
        XCTAssertEqual(presets.first?.name, "Service 14")
        XCTAssertEqual(presets.last?.name, "Service 3")
    }

    func testMCPListsAndStartsSessionTunnelPreset() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let listResponse = try runMCP(
            scriptURL: fixture.scriptURL,
            home: fixture.root,
            messages: [[
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "list_session_tunnel_presets", "arguments": [:]]
            ]]
        )
        let listPayload = try toolTextJSON(listResponse)
        let presets = try XCTUnwrap(listPayload["sessionTunnelPresets"] as? [[String: Any]])
        XCTAssertEqual(presets.first?["name"] as? String, "MySQL")
        XCTAssertEqual(presets.first?["localPort"] as? Int, 13306)

        let process = try startMCP(
            scriptURL: fixture.scriptURL,
            home: fixture.root,
            message: [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "start_session_tunnel",
                    "arguments": ["tab": "tab-1", "preset": "MySQL", "metadata": true]
                ]
            ]
        )
        let toolRequest = try answerRequest(home: fixture.root)
        XCTAssertEqual(toolRequest["tunnelName"] as? String, "MySQL")
        XCTAssertEqual(toolRequest["targetHost"] as? String, "127.0.0.1")
        XCTAssertEqual(toolRequest["targetPort"] as? Int, 3306)
        XCTAssertEqual(toolRequest["localPort"] as? Int, 13306)
        try answer(request: toolRequest, home: fixture.root)
        let startResponse = try process.finish()
        XCTAssertNil(startResponse["error"])
    }

    func testMCPToolCatalogExposesTunnelPresetCapabilities() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try runMCP(
            scriptURL: fixture.scriptURL,
            home: fixture.root,
            messages: [[
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list",
                "params": [:]
            ]]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "list_tabs",
            "read_screen",
            "read_history",
            "read_commands",
            "create_tab",
            "open_ssh_profile",
            "list_session_tunnels",
            "start_session_tunnel",
            "list_session_tunnel_presets",
            "stop_session_tunnel",
            "list_shortcuts",
            "play_shortcut",
            "send_text",
            "send_key"
        ])
        let startTool = try XCTUnwrap(tools.first { $0["name"] as? String == "start_session_tunnel" })
        let schema = try XCTUnwrap(startTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["preset"])
    }

    private func makeFixture() throws -> (root: URL, scriptURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qterm-preset-mcp-\(UUID().uuidString)", isDirectory: true)
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
            "sessionTunnelPresets": [[
                "id": "preset-1",
                "name": "MySQL",
                "targetHost": "127.0.0.1",
                "targetPort": 3306,
                "localPort": 13306,
                "lastUsedAt": "2026-08-11T00:00:00Z",
                "useCount": 3
            ]],
            "tabs": [[
                "id": "tab-1",
                "index": 1,
                "title": "server",
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

    private func runMCP(
        scriptURL: URL,
        home: URL,
        messages: [[String: Any]]
    ) throws -> [String: Any] {
        let process = try startMCP(scriptURL: scriptURL, home: home, message: messages[0])
        return try process.finish()
    }

    private func startMCP(
        scriptURL: URL,
        home: URL,
        message: [String: Any]
    ) throws -> MCPProcess {
        let data = try JSONSerialization.data(withJSONObject: message)
        let input = Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
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
        return MCPProcess(process: process, output: stdout)
    }

    private func answerRequest(home: URL) throws -> [String: Any] {
        let requests = home.appendingPathComponent(
            "Library/Application Support/QTerm/Tools/requests",
            isDirectory: true
        )
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
            if let file = files.first(where: { $0.pathExtension == "json" }) {
                return try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw XCTSkip("MCP request file was not created")
    }

    private func answer(request: [String: Any], home: URL) throws {
        let id = try XCTUnwrap(request["id"] as? String)
        let responses = home.appendingPathComponent(
            "Library/Application Support/QTerm/Tools/responses",
            isDirectory: true
        )
        let response: [String: Any] = [
            "schemaVersion": 1,
            "app": "QTerm",
            "version": "test",
            "id": id,
            "ok": true,
            "snapshotSequence": 8,
            "action": "start_session_tunnel",
            "tabID": "tab-1",
            "message": "starting"
        ]
        try JSONSerialization.data(withJSONObject: response).write(
            to: responses.appendingPathComponent("\(id).json")
        )
    }

    private func toolTextJSON(_ response: [String: Any]) throws -> [String: Any] {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private struct MCPProcess {
    let process: Process
    let output: Pipe

    func finish() throws -> [String: Any] {
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let separator = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(data.range(of: separator))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(data[range.upperBound...])) as? [String: Any]
        )
    }
}
