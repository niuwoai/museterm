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
        XCTAssertEqual(preferences.fontSize, 14)
    }

    func testTerminalPalettesProvideAnsi16Colors() {
        for palette in TerminalColorPalette.allCases {
            XCTAssertEqual(palette.swiftTermColors.count, 16)
            XCTAssertEqual(palette.nsColors.count, 16)
        }
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

}
