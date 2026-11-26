import XCTest

final class TerminalAgentUITests: XCTestCase {
    @MainActor
    func testOrdinaryReminderUnifiesBadgeListAndCount() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-ordinary-ui-\(UUID())")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES",
            "-notifications.enabled", "YES", "-notifications.showInactiveTabBadges", "YES",
            "-ui-testing-agent-state", "-ui-testing-terminal-attention"]
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: tools) }
        let entry = app.buttons["agent-attention-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.label.contains("1"))
        let unread = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal-unread-")).firstMatch
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "ordinary-attention-count-and-badge"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["Hide tab list"].click()
        XCTAssertTrue(entry.label.contains("1"))
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        entry.click()
        XCTAssertTrue(app.staticTexts["Pending items"].waitForExistence(timeout: 5))
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attention-item-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.label.contains("Terminal bell"))
        XCTAssertTrue(item.label.contains("2 reminders combined"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ordinary-attention-unified"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        item.click()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "0"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(unread.exists)
        XCTAssertFalse(item.exists)
    }

    @MainActor
    func testAgentBadgeSurvivesSidebarToggleWithoutInputTakeover() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-agent-ui-\(UUID())")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = tools.path
        defer { try? FileManager.default.removeItem(at: tools) }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-terminal.showsTabList", "YES", "-terminal.sidebarExpandedWidth", "220",
            "-agent.monitoringEnabled", "YES", "-notifications.enabled", "NO",
            "-SUEnableAutomaticChecks", "NO", "-ui-testing-agent-state", "-ui-testing-sidebar-title"]
        app.launch()
        defer { app.terminate() }
        let rowPrefix = "project-tab-"
        let badge = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", rowPrefix, "Fixture task")
        ).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(badge.label.contains("Codex"))
        XCTAssertTrue(badge.label.contains("Needs attention"))
        XCTAssertTrue(badge.label.contains("Integration report"))
        let directoryTitle = "muchtoken"
        let paneTitle = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "pane-focus-", directoryTitle
        )).firstMatch
        XCTAssertTrue(paneTitle.waitForExistence(timeout: 5))
        let sidebarTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value == %@ OR label == %@)", rowPrefix, directoryTitle, directoryTitle
        )).firstMatch
        XCTAssertTrue(sidebarTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(sidebarTitle.frame.width, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "agent-state-expanded"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Hide tab list"].click()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(badge.label.contains("Codex"))
        XCTAssertTrue(sidebarTitle.exists)
        XCTAssertGreaterThan(sidebarTitle.frame.width, 0)
        XCTAssertFalse(app.buttons["Unlock and take control"].exists)
        let compact = XCTAttachment(screenshot: app.screenshot())
        compact.name = "agent-state-compact"
        compact.lifetime = .keepAlways
        add(compact)
    }

    @MainActor
    func testReadQuestionRemainsInAttentionListAndCompactEntryIsAccessible() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-attention-ui-\(UUID())")
        app.launchEnvironment["MUSETERM_AGENT_TEST_TOOL_ROOT"] = tools.path
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
