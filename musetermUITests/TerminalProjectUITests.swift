import XCTest

final class TerminalProjectUITests: XCTestCase {
    @MainActor
    func testProjectSplitInputAndFocusStayOnTheCorrectTerminal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-project-ui-\(UUID())")
        app.launchEnvironment["QTERM_AGENT_TEST_TOOL_ROOT"] = root.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO",
            "-terminal.skipRunningTabCloseConfirmation", "YES", "-ui-testing-agent-state", "-ui-testing-project-workspace"]
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
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
        app.typeText("printf qterm_first_pane_ok\n")
        _ = try waitState(root) { state in
            (state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == first }?["screen"] as? String != nil
                && (state["selectedTabID"] as? String) == first
                && ((state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == first }?["screen"] as? String)?.contains("qterm_first_pane_ok") == true
        }
        secondFocus.click()
        app.typeText("printf qterm_second_pane_ok\n")
        _ = try waitState(root) { state in
            (state["selectedTabID"] as? String) == second
                && ((state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == second }?["screen"] as? String)?.contains("qterm_second_pane_ok") == true
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
