import XCTest

final class TerminalProjectUITests: XCTestCase {
    @MainActor
    func testImportSearchAndCancelKeepOriginalTerminal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("museterm-import-ui-\(UUID())")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = root.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO"]
        app.launch()
        // Xcode's sandboxed runner can read this host-owned fixture, but only
        // the unsandboxed QA application may create/write it. Retain for diagnostics.
        defer { app.terminate() }
        let before = try waitState(root) { ($0["tabs"] as? [[String: Any]])?.count == 1 }
        app.buttons["project-import"].click()
        let search = app.textFields["project-import-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click(); search.typeText("museterm-no-match-\(UUID())")
        let confirm = app.buttons["project-import-confirm"]
        XCTAssertTrue(confirm.exists)
        XCTAssertFalse(confirm.isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertFalse(search.exists)
        let after = try waitState(root) { ($0["tabs"] as? [[String: Any]])?.count == 1 }
        XCTAssertEqual(after["selectedTabID"] as? String, before["selectedTabID"] as? String)
        XCTAssertEqual((after["tabs"] as? [[String: Any]])?.first?["id"] as? String,
                       (before["tabs"] as? [[String: Any]])?.first?["id"] as? String)
        let toggle = app.buttons["project-section-toggle"]
        toggle.click()
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-tab-")).firstMatch.exists)
        XCTAssertTrue(app.buttons["pane-focus-\(try XCTUnwrap(before["selectedTabID"] as? String))"].exists)
        toggle.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-tab-")).firstMatch.exists)
    }

    @MainActor
    func testProjectSplitInputAndFocusStayOnTheCorrectTerminal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("museterm-project-ui-\(UUID())")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = root.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO",
            "-terminal.skipRunningTabCloseConfirmation", "YES", "-ui-testing-agent-state", "-ui-testing-project-workspace"]
        app.launch()
        defer { app.terminate() }
        let initial = try waitState(root) { ($0["tabs"] as? [[String: Any]])?.count == 1 }
        let first = try XCTUnwrap((initial["tabs"] as? [[String: Any]])?.first?["id"] as? String)
        let split = app.buttons["pane-split-right-\(first)"]
        XCTAssertTrue(split.waitForExistence(timeout: 10))
        split.click()
        let divided = try waitState(root) { ($0["tabs"] as? [[String: Any]])?.count == 2 }
        let second = try XCTUnwrap((divided["tabs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.first { $0 != first })
        let firstFocus = app.buttons["pane-focus-\(first)"]
        let secondFocus = app.buttons["pane-focus-\(second)"]
        XCTAssertTrue(firstFocus.exists)
        XCTAssertTrue(secondFocus.exists)
        firstFocus.click()
        app.typeText("printf museterm_first_pane_ok\n")
        _ = try waitState(root) { state in
            (state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == first }?["screen"] as? String != nil
                && (state["selectedTabID"] as? String) == first
                && ((state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == first }?["screen"] as? String)?.contains("museterm_first_pane_ok") == true
        }
        secondFocus.click()
        app.typeText("printf museterm_second_pane_ok\n")
        _ = try waitState(root) { state in
            (state["selectedTabID"] as? String) == second
                && ((state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == second }?["screen"] as? String)?.contains("museterm_second_pane_ok") == true
        }
        app.buttons["pane-split-down-\(second)"].click()
        _ = try waitState(root) { ($0["tabs"] as? [[String: Any]])?.count == 3 }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "project-three-live-panes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["project-create"].click()
        let name = app.textFields["project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Native integration")
        app.buttons["project-save"].click()
        let created = try waitState(root) { state in
            (state["projectLayout"] as? [String: Any])?["projects"] as? [[String: Any]] != nil
                && ((state["projectLayout"] as? [String: Any])?["projects"] as? [[String: Any]])?.count == 2
        }
        let projects = try XCTUnwrap((created["projectLayout"] as? [String: Any])?["projects"] as? [[String: Any]])
        let original = try XCTUnwrap(projects.first { $0["name"] as? String == "Project" }?["id"] as? String)
        app.buttons["project-\(original)"].click()
        XCTAssertTrue(firstFocus.waitForExistence(timeout: 5))
        XCTAssertTrue(secondFocus.exists)
        app.buttons["pane-close-\(second)"].click()
        let closed = try waitState(root) { state in
            !((state["tabs"] as? [[String: Any]])?.contains { $0["id"] as? String == second } ?? true)
        }
        XCTAssertEqual((closed["tabs"] as? [[String: Any]])?.count, 3)
    }

    @MainActor
    private func waitState(_ root: URL, matching: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        var result: [String: Any]?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], matching(state) else { return false }
            result = state
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
        return try XCTUnwrap(result)
    }
}
