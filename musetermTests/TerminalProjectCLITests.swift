import XCTest
@testable import museterm

@MainActor
final class TerminalProjectCLITests: XCTestCase {
    func testQuietLayoutRenameAndResizePublishWithoutTerminalOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-project-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let terminal = try XCTUnwrap(workspace.selectedTab)
        _ = try workspace.splitTerminal(terminal.id, axis: .horizontal)
        let project = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        let split = try XCTUnwrap(workspace.projectLayout.selectedTab?.layout.splitIDs.first)
        let bridge = TerminalToolBridge(rootDirectory: root)
        bridge.attach(workspace: workspace)
        defer { bridge.stop() }
        func published(_ matches: (TerminalProjectLayout) -> Bool) async throws -> Int {
            for _ in 0..<240 {
                if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let layout = value["projectLayout"],
                   let json = try? JSONSerialization.data(withJSONObject: layout),
                   let decoded = try? JSONDecoder().decode(TerminalProjectLayout.self, from: json), matches(decoded) {
                    return try XCTUnwrap(value["snapshotSequence"] as? Int)
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTFail("Quiet layout mutation did not publish")
            throw TerminalRuntimeConnectionError.timedOut
        }
        let original = workspace.projectLayout
        let first = try await published { $0 == original }
        let events = workspace.sessionRegistry.events.sequence
        let selected = workspace.selectedID
        try workspace.renameProject(project, name: "quiet rename")
        let renamed = workspace.projectLayout
        let second = try await published { $0 == renamed }
        workspace.resizeSplit(split, ratio: 0.37)
        let resized = workspace.projectLayout
        XCTAssertNotEqual(resized, renamed)
        let third = try await published { $0 == resized }
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(third, second)
        XCTAssertEqual(workspace.selectedID, selected)
        XCTAssertEqual(workspace.sessionRegistry.events.sequence, events, "No terminal event should be needed to publish layouts")
        XCTAssertFalse(workspace.tabs.contains(where: \.hasRunningProcess))
    }

    func testTimedOutProjectRequestIsRemovedBeforeUICanReceiveItLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-project-timeout-\(UUID())")
        let toolRoot = root.appendingPathComponent("Library/Application Support/MuseTerm/Tools")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        defer { bridge.stop() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("runtime.json").path) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        bridge.stop()
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let body = """
        def access_token; "timeout-fixture-only"; end
        failed = begin
          project_tool({"operation" => "createProject", "name" => "must-not-arrive-later", "timeout" => 0.2}); false
        rescue => error
          error.message == "MuseTerm did not answer the tool request in time."
        end
        puts JSON.generate({"timedOut" => failed, "requests" => Dir.glob(File.join(REQUESTS, "*.json")).length})
        """
        let script = root.appendingPathComponent("timeout.rb")
        try (definitions + "\n" + body).write(to: script, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby"); process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<200 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !process.isRunning else { XCTFail("Project timeout fixture did not terminate"); return }
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(result["timedOut"] as? Bool, true)
        XCTAssertEqual(result["requests"] as? Int, 0)
    }

    func testGeneratedCLIAndMCPUseActualPairedBridgeAndKeepFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-project-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "MuseTermProjectTools.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.toolBridgeWritesEnabled = false
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        workspace.preferences = preferences
        let original = try XCTUnwrap(workspace.selectedID)
        let toolRoot = root.appendingPathComponent("Library/Application Support/MuseTerm/Tools")
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        defer { bridge.stop() }
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        XCTAssertTrue(MuseTermKeychain.save("project-fixture-only", account: "museterm-cli", serviceName: TerminalToolAccess.keychainServiceName))
        let deniedID = UUID().uuidString
        let disabledRequest: [String: Any] = ["id": deniedID, "action": "project_layout", "clientID": "museterm-cli",
            "authToken": "project-fixture-only", "projectRequest": ["operation": "createProject", "name": "disabled",
                "uiEpoch": workspace.sessionRegistry.events.appEpoch.uuidString,
                "deadlineMonotonic": TerminalProjectToolService.requestMonotonicTime() + 5]]
        try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: disabledRequest),
            to: toolRoot.appendingPathComponent("requests/\(deniedID).json"))
        let disabledResponse = toolRoot.appendingPathComponent("responses/\(deniedID).json")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: disabledResponse.path) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let disabled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: disabledResponse)) as? [String: Any])
        XCTAssertEqual(disabled["error"] as? String, "project_access_denied")
        XCTAssertEqual(workspace.projectLayout.projects.count, 1)
        preferences.toolBridgeWritesEnabled = true
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let body = """
        def access_token; raise "Read accessed credentials"; end
        baseline = project_tool({"operation" => "list"})
        def access_token; "wrong-project-fixture"; end
        denied = begin
          project_tool({"operation" => "createProject", "name" => "denied"}); false
        rescue => error
          error.message == "project_access_denied"
        end
        def access_token; "project-fixture-only"; end
        created = project_tool({"operation" => "createProject", "name" => "review", "directory" => "/private/tmp"})
        id = created.fetch("projectResult").fetch("projectID")
        split = project_tool({"operation" => "split", "terminalID" => "\(original)", "axis" => "vertical"})
        layout_tab = split.fetch("projectResult").fetch("layoutTabID")
        moved = project_tool({"operation" => "moveTab", "layoutTabID" => layout_tab, "projectID" => id})
        mcp = call_tool("project_layout", {"operation" => "list"})
        listed = JSON.parse(mcp.fetch("content").first.fetch("text"))
        puts JSON.generate({"denied" => denied, "baseline" => baseline, "created" => created,
          "split" => split, "moved" => moved, "listed" => listed})
        """
        let script = root.appendingPathComponent("fixture.rb")
        try (definitions + "\n" + body).write(to: script, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby"); process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<400 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(process.isRunning)
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(result["denied"] as? Bool, true)
        XCTAssertEqual(workspace.projectLayout.projects.count, 2)
        XCTAssertEqual(workspace.projectLayout.selectedProjectID,
            ((result["baseline"] as? [String: Any])?["projectResult"] as? [String: Any]).flatMap {
                ($0["layout"] as? [String: Any])?["selectedProjectID"] as? String
            }.flatMap(UUID.init(uuidString:)))
        let listed = try XCTUnwrap((result["listed"] as? [String: Any])?["projectResult"] as? [String: Any])
        XCTAssertEqual(listed["workspaceID"] as? String, workspace.runtimeWorkspaceID.uuidString)
        XCTAssertEqual(listed["revision"] as? UInt64, workspace.projectLayoutRevision)
        XCTAssertTrue(MuseTermCLIInstaller.script.contains("when \"project\" then command_project(ARGV)"))
        try workspace.projectLayout.validate()
    }
}
