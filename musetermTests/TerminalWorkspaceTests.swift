import XCTest
@testable import museterm

final class TerminalWorkspaceTests: XCTestCase {
    private final class RecordingTabCloseConfirmer: TerminalTabCloseConfirming {
        var shouldAllowClose = true
        private(set) var requestedTabTitles: [String] = []

        func shouldClose(tab: TerminalSession) -> Bool {
            requestedTabTitles.append(tab.tabTitle)
            return shouldAllowClose
        }
    }

    private final class ReentrantTabCloseConfirmer: TerminalTabCloseConfirming {
        var reenter: (() -> Void)?
        private(set) var requestedTabTitles: [String] = []
        private var didReenter = false

        func shouldClose(tab: TerminalSession) -> Bool {
            requestedTabTitles.append(tab.tabTitle)
            guard !didReenter else { return true }
            didReenter = true
            reenter?()
            return true
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

    func testShortcutCloseTabDeduplicatesDoubleDispatch() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)
        workspace.select(secondTab)

        workspace.closeSelectedTabFromShortcut(eventTimestamp: 200)
        workspace.closeSelectedTabFromShortcut(eventTimestamp: 200)

        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    func testShortcutCloseTabDeduplicatesCancelledCloseAttempt() throws {
        let confirmer = RecordingTabCloseConfirmer()
        confirmer.shouldAllowClose = false
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        workspace.newTab()
        let selectedTab = try XCTUnwrap(workspace.selectedTab)

        workspace.closeSelectedTabFromShortcut(eventTimestamp: 200)
        workspace.closeSelectedTabFromShortcut(eventTimestamp: 200)

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedID, selectedTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)

        confirmer.shouldAllowClose = true
        workspace.closeSelectedTabFromShortcut(eventTimestamp: 201)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 2)
    }

    func testShortcutCloseTabIgnoresReentrantCloseDuringConfirmation() throws {
        let confirmer = ReentrantTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        confirmer.reenter = { [weak workspace] in
            _ = workspace?.closeSelectedTabFromShortcut(eventTimestamp: 301)
        }
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)
        workspace.select(secondTab)

        workspace.closeSelectedTabFromShortcut(eventTimestamp: 300)

        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles, [secondTab.tabTitle])
    }

    func testCloseSelectedTabIgnoresDirectReentrantCloseDuringConfirmation() throws {
        let confirmer = ReentrantTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        confirmer.reenter = { [weak workspace] in
            _ = workspace?.closeSelectedTab()
        }
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)
        workspace.select(secondTab)

        workspace.closeSelectedTab()

        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles, [secondTab.tabTitle])
    }

    func testCloseSelectedTabRemovesOnlyCurrentTab() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        let firstTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)

        workspace.select(secondTab)
        workspace.closeSelectedTab()

        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    func testCloseSelectedTabCanBeCancelledByConfirmer() throws {
        let confirmer = RecordingTabCloseConfirmer()
        confirmer.shouldAllowClose = false
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        workspace.newTab()
        let selectedTab = try XCTUnwrap(workspace.selectedTab)

        workspace.closeSelectedTab()

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedID, selectedTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    func testClosingLastTabKeepsReplacementTab() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        let originalTab = try XCTUnwrap(workspace.selectedTab)

        workspace.closeSelectedTab()

        let replacementTab = try XCTUnwrap(workspace.selectedTab)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(replacementTab.id, originalTab.id)
        XCTAssertEqual(workspace.selectedID, replacementTab.id)
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
}
