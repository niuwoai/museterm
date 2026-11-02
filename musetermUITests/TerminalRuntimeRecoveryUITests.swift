import CryptoKit
import Darwin
import XCTest

final class TerminalRuntimeRecoveryUITests: XCTestCase {
    @MainActor
    func testNormalApplicationQuitAndRelaunchPreserveOriginalPTYAndSplit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-recovery-ui-\(UUID())")
        let hash = SHA256.hash(data: Data(tools.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let backend = URL(fileURLWithPath: "/private/tmp/qrt-ui-\(getuid())-\(hash)")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO",
            "-terminal.skipRunningTabCloseConfirmation", "YES", "-ui-testing-agent-state",
            "-ui-testing-project-workspace", "-ui-testing-runtime"]
        defer {
            app.terminate()
            do {
                try closePrivateBackend(backend)
                try? FileManager.default.removeItem(at: backend)
                try? FileManager.default.removeItem(at: tools)
            } catch { XCTFail("Could not clean up the private test backend") }
        }
        app.launch()
        let initial = try waitState(tools) { Self.runtimeTabs($0).count == 1 }
        let first = try XCTUnwrap(Self.runtimeTabs(initial).first?["id"] as? String)
        let split = app.buttons["pane-split-right-\(first)"]
        XCTAssertTrue(split.waitForExistence(timeout: 10))
        split.click()
        let divided = try waitState(tools) { Self.runtimeTabs($0).count == 2 }
        let before = Self.runtimeTabs(divided)
        let identities = before.compactMap { tab -> String? in
            guard let id = tab["id"] as? String, let runtime = tab["runtime"] as? [String: Any],
                  let generation = runtime["generation"] as? String, let pid = runtime["pid"] as? Int else { return nil }
            return "\(id):\(generation):\(pid)"
        }
        XCTAssertEqual(identities.count, 2)
        let focus = app.buttons["pane-focus-\(first)"]
        focus.click()
        // The final marker is assembled by printf and cannot match shell echo.
        app.typeText("printf '\\n__SESSION_%s\\n' SURVIVES\n")
        let beforeQuit = try waitState(tools) { state in
            Self.runtimeTabs(state).first { $0["id"] as? String == first }?["screen"] as? String != nil
                && (Self.runtimeTabs(state).first { $0["id"] as? String == first }?["screen"] as? String)?.contains("__SESSION_SURVIVES") == true
        }
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Quit must use the actual application delegate")
        for tab in before {
            let runtime = try XCTUnwrap(tab["runtime"] as? [String: Any])
            let pid = try XCTUnwrap((runtime["pid"] as? Int).flatMap(Int32.init(exactly:)))
            XCTAssertEqual(kill(pid, 0), 0, "Original PTY process must outlive the UI")
        }
        try FileManager.default.removeItem(at: tools.appendingPathComponent("state.json"))
        app.launch()
        let recovered = try waitState(tools) { state in
            Self.runtimeTabs(state).count == 2
                && Self.runtimeTabs(state).contains { ($0["screen"] as? String)?.contains("__SESSION_SURVIVES") == true }
        }
        let restoredIdentities = Self.runtimeTabs(recovered).compactMap { tab -> String? in
            guard let id = tab["id"] as? String, let runtime = tab["runtime"] as? [String: Any],
                  let generation = runtime["generation"] as? String, let pid = runtime["pid"] as? Int else { return nil }
            return "\(id):\(generation):\(pid)"
        }
        XCTAssertEqual(Set(restoredIdentities), Set(identities))
        let oldLayout = try XCTUnwrap(beforeQuit["projectLayout"] as? [String: Any])
        let newLayout = try XCTUnwrap(recovered["projectLayout"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(oldLayout["projects"]), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: XCTUnwrap(newLayout["projects"]), options: .sortedKeys))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "same-real-pty-after-application-relaunch"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor
    func testColdApplicationLaunchRestoresUsableLocalTerminalAfterServiceExit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-cold-recovery-ui-\(UUID())")
        let hash = SHA256.hash(data: Data(tools.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let backend = URL(fileURLWithPath: "/private/tmp/qrt-ui-\(getuid())-\(hash)")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO",
            "-terminal.skipRunningTabCloseConfirmation", "YES", "-ui-testing-agent-state",
            "-ui-testing-project-workspace", "-ui-testing-runtime"]
        defer {
            app.terminate()
            do {
                try closePrivateBackend(backend)
                try FileManager.default.removeItem(at: backend)
                try FileManager.default.removeItem(at: tools)
            } catch { XCTFail("Could not clean up the private cold-start backend: \(error)") }
        }
        app.launch()
        let initial = try waitState(tools) { Self.runtimeTabs($0).count == 1 }
        let original = try XCTUnwrap(Self.runtimeTabs(initial).first)
        let terminalID = try XCTUnwrap(original["id"] as? String)
        let oldGeneration = try XCTUnwrap((original["runtime"] as? [String: Any])?["generation"] as? String)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        // Preserve the UI recovery record, but remove its process-owning service
        // to reproduce a reboot or an update that stopped the old helper.
        try closePrivateBackend(backend)
        try FileManager.default.removeItem(at: tools.appendingPathComponent("state.json"))
        app.launch()
        let recovered = try waitState(tools) { state in
            Self.runtimeTabs(state).contains { $0["id"] as? String == terminalID }
        }
        let restored = try XCTUnwrap(Self.runtimeTabs(recovered).first { $0["id"] as? String == terminalID })
        XCTAssertNotEqual((restored["runtime"] as? [String: Any])?["generation"] as? String, oldGeneration)
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        app.buttons["pane-focus-\(terminalID)"].click()
        app.typeText("printf '\\n__COLD_START_%s\\n' READY\n")
        _ = try waitState(tools) { state in
            Self.runtimeTabs(state).contains {
                $0["id"] as? String == terminalID && ($0["screen"] as? String)?.contains("__COLD_START_READY") == true
            }
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "usable-local-terminal-after-service-restart"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    private static func runtimeTabs(_ state: [String: Any]) -> [[String: Any]] {
        (state["tabs"] as? [[String: Any]] ?? []).filter { ($0["runtime"] as? [String: Any])?["connected"] as? Bool == true }
    }

    @MainActor
    private func waitState(_ root: URL, matching: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        var result: [String: Any]?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], matching(state) else { return false }
            result = state
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        return try XCTUnwrap(result)
    }

    private func closePrivateBackend(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-capability").path) else { return }
        let client = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/support/runtime_probe_client.rb")
        let code = #"""
require "timeout"
Timeout.timeout(12) do
  root = ARGV.fetch(0)
  client = RuntimeProbeClient.new(root)
  state = client.request("list")
  abort "Private list failed" unless state["ok"]
  state.fetch("sessions").each do |session|
    result = client.request("close", {"sessionID" => session.fetch("id"), "generation" => session.fetch("generation"), "controlEpoch" => session.fetch("controlEpoch")})
    abort "Private close failed" unless result["ok"]
  end
  abort "Private shutdown failed" unless client.request("shutdownIfEmpty")["ok"]
  client.close
  loop do
    begin
      socket = UNIXSocket.new(File.join(root, "runtime.sock")); socket.close
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      break
    end
    sleep 0.05
  end
end
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-r", client.path, "-e", code, root.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "PrivateBackendCleanup", code: Int(process.terminationStatus)) }
    }
}
