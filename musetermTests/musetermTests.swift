//
//  musetermTests.swift
//  musetermTests
//
//  Created by rocky on 2026/6/30.
//

import Foundation
import XCTest
@testable import museterm

final class musetermTests: XCTestCase {

    func testDefaultPreferencesUseSeaSaltSkin() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.skin, TerminalVisualSkin.seaSalt)
        XCTAssertEqual(preferences.colorPalette, TerminalColorPalette.apple)
        XCTAssertTrue(preferences.glassEnabled)
        XCTAssertTrue(preferences.showsTabList)
        XCTAssertEqual(preferences.fontSize, 14)
    }

    func testTerminalPalettesProvideAnsi16Colors() {
        for palette in TerminalColorPalette.allCases {
            XCTAssertEqual(palette.swiftTermColors.count, 16)
            XCTAssertEqual(palette.nsColors.count, 16)
        }
    }

    func testToolInputMapsNamedControlKeys() {
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "enter", rawBytes: nil), [0x0D])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "ctrl-c", rawBytes: nil), [0x03])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "tab", rawBytes: nil), [0x09])
        XCTAssertEqual(TerminalToolInput.bytes(text: "abc", key: nil, rawBytes: nil), Array("abc".utf8))
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: nil, rawBytes: [1, 2, 3]), [1, 2, 3])
    }

    func testCliInstallerScriptExposesMCPAndTerminalCommands() {
        let script = MuseTermCLIInstaller.script

        XCTAssertTrue(script.contains("museterm tabs"))
        XCTAssertTrue(script.contains("museterm screen"))
        XCTAssertTrue(script.contains("museterm history"))
        XCTAssertTrue(script.contains("museterm input"))
        XCTAssertTrue(script.contains("museterm key"))
        XCTAssertTrue(script.contains("\"tools/call\""))
        XCTAssertTrue(script.contains("read_screen"))
        XCTAssertTrue(script.contains("send_key"))
    }

    func testWorkspaceCreatesAndSelectsTabs() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertNotEqual(firstTab.id, secondTab.id)
        XCTAssertEqual(workspace.selectedID, secondTab.id)
    }

    func testShortcutNewTabDeduplicatesDoubleDispatch() {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)

        workspace.newTabFromShortcut(eventTimestamp: 100)
        workspace.newTabFromShortcut(eventTimestamp: 100)

        XCTAssertEqual(workspace.tabs.count, 2)

        workspace.newTabFromShortcut(eventTimestamp: 101)
        XCTAssertEqual(workspace.tabs.count, 3)
    }

    func testWorkspaceCyclesTabsWithKeyboardActions() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)

        workspace.selectNextTab()
        XCTAssertEqual(workspace.selectedID, firstTab.id)

        workspace.selectPreviousTab()
        XCTAssertEqual(workspace.selectedID, thirdTab.id)

        workspace.selectTab(at: 1)
        XCTAssertEqual(workspace.selectedID, secondTab.id)

        workspace.selectTab(at: 99)
        XCTAssertEqual(workspace.selectedID, secondTab.id)
    }

    func testTabTitleHidesLocalUserHostTitle() {
        let tab = TerminalSession(sequence: 1)
        tab.title = "\(NSUserName())@\(ProcessInfo.processInfo.hostName):~"
        tab.currentDirectory = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertNotEqual(tab.tabTitle, tab.title)
        XCTAssertEqual(tab.tabTitle, FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
        XCTAssertNil(tab.tabSubtitle)
    }

    func testTabTitleKeepsRemoteUserHostTitle() {
        let tab = TerminalSession(sequence: 1)
        tab.title = "deploy@production-box:/srv/app"
        tab.currentDirectory = "/srv/app"

        XCTAssertEqual(tab.tabTitle, "deploy@production-box")
        XCTAssertEqual(tab.tabSubtitle, "app")
    }

    func testTerminalShortcutRecorderProtectsEchoOffInput() throws {
        let started = Date(timeIntervalSince1970: 100)
        let recorder = TerminalShortcutRecorder(startedAt: started)

        recorder.record(data: Array("ls\n".utf8), echoEnabled: true, now: started.addingTimeInterval(0.2))
        recorder.record(data: Array("secret\n".utf8), echoEnabled: false, now: started.addingTimeInterval(0.5))

        let shortcut = try XCTUnwrap(recorder.finish(title: "Deploy", finishedAt: started.addingTimeInterval(1)))
        XCTAssertEqual(shortcut.events.count, 2)
        XCTAssertFalse(shortcut.events[0].requiresEchoOff)
        XCTAssertTrue(shortcut.events[1].requiresEchoOff)
        XCTAssertTrue(shortcut.hasProtectedInput)
        XCTAssertEqual(shortcut.events[1].bytes, [])
        XCTAssertEqual(shortcut.events[1].transientProtectedBytes, Array("secret\n".utf8))
    }

    func testSSHConfigRendersPerHopIdentityAndProxyJump() {
        let firstJump = SSHJumpHost(
            name: "bastion",
            host: "jump1.example.com",
            user: "ops",
            port: 2222,
            identityFiles: ["~/.ssh/jump1"]
        )
        let secondJump = SSHJumpHost(
            host: "jump2.example.com",
            user: "root",
            port: 22,
            identityFiles: ["~/.ssh/jump2"]
        )
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            identityFiles: ["~/.ssh/prod"],
            jumpHosts: [firstJump, secondJump],
            extraOptions: ["ServerAliveInterval 30"]
        )

        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("Host museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("IdentityFile "))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-2"))
        XCTAssertTrue(config.contains("HostName prod.internal"))
        XCTAssertTrue(config.contains("ServerAliveInterval 30"))
    }

    func testOutputInsightAnalyzerDetectsCommonSignals() {
        let output = """
        ERROR failed to compile Sources/App.swift:42
        warning: deprecated option
        See https://example.com/build/123
        commit abc1234 fixed the issue
        at Module.run (/srv/app/index.js:10:2)
        """

        let kinds = Set(TerminalOutputInsightAnalyzer.insights(in: output).map(\.kind))

        XCTAssertTrue(kinds.contains(.error))
        XCTAssertTrue(kinds.contains(.warning))
        XCTAssertTrue(kinds.contains(.url))
        XCTAssertTrue(kinds.contains(.filePath))
        XCTAssertTrue(kinds.contains(.commitHash))
        XCTAssertTrue(kinds.contains(.stackTrace))
    }

    func testOutputInsightAnalyzerFormatsJSONSummary() throws {
        let output = #"{"z":2,"a":{"ok":true}}"#

        let formatted = try XCTUnwrap(TerminalOutputInsightAnalyzer.formattedJSON(in: output))
        XCTAssertTrue(formatted.contains(#""a" : {"#))
        XCTAssertTrue(formatted.contains(#""ok" : true"#))

        let summary = TerminalOutputInsightAnalyzer.summary(in: output)
        XCTAssertTrue(summary.contains("formattedJSON:"))
        XCTAssertTrue(summary.contains("json:"))
    }

}
