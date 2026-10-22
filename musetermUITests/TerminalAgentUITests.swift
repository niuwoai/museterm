import XCTest

final class TerminalAgentUITests: XCTestCase {
    @MainActor
    func testAgentBadgeSurvivesSidebarToggleWithoutInputTakeover() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-agent-ui-\(UUID())")
        app.launchEnvironment["QTERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        defer { try? FileManager.default.removeItem(at: tools) }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-terminal.showsTabList", "YES", "-agent.monitoringEnabled", "YES", "-notifications.enabled", "NO", "-ui-testing-agent-state"]
        app.launch()
        defer { app.terminate() }
        let badge = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "agent-state-")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(badge.label.contains("Codex"))
        XCTAssertTrue(badge.label.contains("Needs attention"))
        XCTAssertTrue(badge.label.contains("Integration report"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "agent-state-expanded"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Hide tab list"].click()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(badge.label.contains("Codex"))
        XCTAssertFalse(app.buttons["Unlock and take control"].exists)
        let compact = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compact.name = "agent-state-compact"
        compact.lifetime = .keepAlways
        add(compact)
    }

    @MainActor
    func testReadQuestionRemainsInAttentionListAndCompactEntryIsAccessible() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-attention-ui-\(UUID())")
        app.launchEnvironment["QTERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-terminal.showsTabList", "YES", "-agent.monitoringEnabled", "YES", "-notifications.enabled", "NO", "-ui-testing-agent-state"]
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: tools) }
        let entry = app.buttons["agent-attention-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.label.contains("1"))
        entry.click()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attention-item-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        if !item.exists { entry.click() }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        let viewed = NSPredicate(format: "label CONTAINS %@", "Viewed; still awaiting your answer")
        expectation(for: viewed, evaluatedWith: item)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "agent-attention-read-question"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.buttons["Hide tab list"].click()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("1"))
    }

    @MainActor
    func testAttentionCanFocusDetachedPanel() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES", "-agent.monitoringEnabled", "YES",
            "-notifications.enabled", "NO", "-ui-testing-agent-state", "-ui-testing-agent-detached"]
        app.launch()
        defer { app.terminate() }
        // Query the second window directly: counting the complete AX snapshot can time out
        // under desktop load even when both windows have already been drawn.
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 30))
        let entry = app.buttons["agent-attention-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attention-item-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertLessThan(app.windows.element(boundBy: 0).frame.width, 900)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "agent-attention-detached-focus"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
