//
//  musetermUITests.swift
//  musetermUITests
//
//  Created by rocky on 2026/6/30.
//

import XCTest

final class musetermUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPrimaryIconButtonsExposeLocalizedAccessibilityLabels() throws {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Tasks and Ports"].exists)
    }

    @MainActor
    func testSettingsSidebarSearchAndAdvancedInspector() throws {
        let app = configuredApplication(skin: "seaSalt")
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].click()

        let settingsSearch = app.textFields["Search settings"]
        XCTAssertTrue(settingsSearch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AI"].exists)
        XCTAssertTrue(app.buttons["MCP & Tools"].exists)
        attachScreenshot(app, named: "settings-light")

        settingsSearch.click()
        settingsSearch.typeText("AI")
        XCTAssertTrue(app.buttons["AI"].exists)
        XCTAssertFalse(app.buttons["Appearance"].exists)
        XCTAssertTrue(app.staticTexts["AI Provider"].waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Command Search"].waitForExistence(timeout: 5))
        app.buttons["Command Search"].click()
        XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 5))
        app.buttons["Advanced"].click()
        XCTAssertTrue(app.buttons["Copy Runbook"].exists)
    }

    @MainActor
    func testNewTabCommandPaletteSSHFixtureAndCloseConfirmation() throws {
        let app = configuredApplication(extraArguments: ["-ui-testing-ssh-fixture"])
        app.launch()

        XCTAssertTrue(app.buttons["New tab"].waitForExistence(timeout: 10))
        app.buttons["New tab"].click()
        XCTAssertTrue(app.staticTexts["⌘2"].waitForExistence(timeout: 5))

        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.textFields["Search commands, paths, hosts, and actions"]
                .waitForExistence(timeout: 5)
        )
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(app.buttons["SSH Hosts"].waitForExistence(timeout: 5))
        app.buttons["SSH Hosts"].click()
        let sshFixture = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "UI Test Host"))
            .firstMatch
        XCTAssertTrue(sshFixture.waitForExistence(timeout: 5))

        app.typeKey("2", modifierFlags: [.command])
        app.typeText("sleep 60")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["Close running tab?"].waitForExistence(timeout: 5))
        app.dialogs.firstMatch.buttons["Cancel"].click()
    }

    @MainActor
    func testCommandPaletteKeepsTypedTextInSearchField() throws {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.buttons["New tab"].waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .shift])

        let searchField = app.textFields["Search commands, paths, hosts, and actions"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        // 留出时间让 SwiftUI 的自动聚焦与终端侧的延迟聚焦都执行完，
        // 再输入：此时的键盘焦点属于命令面板，而不是终端。
        Thread.sleep(forTimeInterval: 1.0)
        app.typeText("settings")

        XCTAssertEqual(
            searchField.value as? String,
            "settings",
            "命令面板打开时，键入的文字应进入搜索框，而不是被终端接收"
        )
    }

    @MainActor
    func testAICommandComposerMenusAndTwoLineInput() throws {
        let app = configuredApplication(extraArguments: [
            "-ui-testing-ai-command-composer",
            "-ai.provider", "someIM",
            "-ai.model", "ui-test-custom-model"
        ])
        app.launch()
        app.activate()

        XCTAssertTrue(app.buttons["New tab"].waitForExistence(timeout: 10), app.debugDescription)
        app.menuBars.menuBarItems["Tab"].click()
        app.menuItems["AI Assistant"].click()

        let query = app.descendants(matching: .any)["aiCommandQuery"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(query.frame.height, 30)
        XCTAssertGreaterThanOrEqual(
            app.staticTexts["Provider"].frame.minY - query.frame.minY,
            44
        )

        let model = app.popUpButtons["Model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "ui-test-custom-model")
        model.click()
        app.menuItems["someim-auto-flash"].click()
        XCTAssertEqual(model.value as? String, "someim-auto-flash")

        let provider = app.popUpButtons["Provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.click()
        app.menuItems["Google Gemini"].click()
        XCTAssertEqual(provider.value as? String, "Google Gemini")
        XCTAssertEqual(model.value as? String, "gemini-2.5-pro")
        attachScreenshot(app, named: "ai-command-composer")
    }

    @MainActor
    func testDarkAppearanceScreenshot() throws {
        let app = configuredApplication(skin: "midnight")
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].click()
        XCTAssertTrue(app.textFields["Search settings"].waitForExistence(timeout: 5))
        attachScreenshot(app, named: "settings-dark")
    }

    @MainActor
    func testSessionTunnelShowsTerminalMaskAndInspector() throws {
        let app = configuredApplication(
            skin: "midnight",
            extraArguments: ["-ui-testing-session-tunnel-fixture"]
        )
        app.launch()

        let createButton = app.buttons["sessionTunnelCreateButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        createButton.click()

        let startButton = app.buttons["sessionTunnelStartButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["sessionTunnelTargetHost"].exists)
        XCTAssertTrue(app.textFields["sessionTunnelLocalPort"].exists)
        startButton.click()

        let mask = app.descendants(matching: .any)["sessionTunnelMask"].firstMatch
        let inspector = app.descendants(matching: .any)["sessionTunnelInspector"].firstMatch
        XCTAssertTrue(mask.waitForExistence(timeout: 15))
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["sessionTunnelPhase.running"].firstMatch
                .waitForExistence(timeout: 15)
        )
        attachScreenshot(app, named: "session-tunnel-mask-inspector")

        let stopButton = app.buttons["sessionTunnelStopButton"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.click()
        XCTAssertTrue(mask.waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func configuredApplication(
        skin: String = "seaSalt",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-terminal.showsTabList", "YES",
            "-terminal.skin", skin,
            "-terminal.skipRunningTabCloseConfirmation", "NO"
        ]
        app.launchArguments += extraArguments
        return app
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
