import XCTest

final class TerminalPreviewUITests: XCTestCase {
    @MainActor
    func testMarkdownSourceDetachDockImageAndTerminalInput() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let root = URL(fileURLWithPath: "/private/tmp/qterm-preview-ui-\(UUID())")
        app.launchEnvironment["QTERM_AGENT_TEST_TOOL_ROOT"] = root.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-notifications.enabled", "NO",
            "-SUEnableAutomaticChecks", "NO", "-ui-testing-preview"]
        app.launch()
        defer { app.terminate() }
        let sidebar = app.descendants(matching: .any)["terminal-preview-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        let heading = app.webViews.staticTexts["Preview acceptance"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        app.buttons["Source"].click()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-preview-raw"].waitForExistence(timeout: 5))
        app.buttons["Open in separate window"].click()
        let dock = app.buttons["Return to sidebar"]
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        XCTAssertFalse(sidebar.exists)
        dock.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.buttons["Close preview"].click()
        XCTAssertFalse(sidebar.exists)
        app.buttons["terminal-preview-open"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.dialogs.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeText(root.appendingPathComponent("preview-image.png").path)
        app.typeKey(.return, modifierFlags: [])
        try XCTUnwrap(app.buttons.matching(identifier: "Preview image or Markdown").allElementsBoundByIndex.last).click()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-preview-image"].waitForExistence(timeout: 10))
        app.buttons["Zoom in"].click()
        app.buttons["Fit to window"].click()
        app.buttons["Close preview"].click()
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any]
        let id = try XCTUnwrap(state?["selectedTabID"] as? String)
        app.buttons["pane-focus-\(id)"].click()
        app.typeText("printf 'preview_terminal_ok\\n'\n")
        let success = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabs = state["tabs"] as? [[String: Any]] else { return false }
            return tabs.first?["screen"] as? String != nil && (tabs.first?["screen"] as? String)?.contains("preview_terminal_ok") == true
        }
        expectation(for: success, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways
        add(attachment)
    }
}
