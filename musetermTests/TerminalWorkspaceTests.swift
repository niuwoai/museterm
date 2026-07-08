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

    func testNewLocalTabInheritsSelectedLocalTabDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        firstTab.currentDirectory = directory.path

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertEqual(secondTab.currentDirectory, directory.path)
        XCTAssertEqual(secondTab.launchConfiguration.localStartDirectory, directory.path)
    }

    func testNewLocalTabDoesNotInheritSelectedSSHTabDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        workspace.openSSH(profile: SSHConnectionProfile(host: "example.com"))
        let sshTab = try XCTUnwrap(workspace.selectedTab)
        sshTab.currentDirectory = directory.path

        workspace.newTab()
        let localTab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertNil(localTab.currentDirectory)
        XCTAssertNil(localTab.launchConfiguration.localStartDirectory)
    }

    func testExplicitNewLocalTabDirectoryOverridesSelectedTabDirectory() throws {
        let selectedDirectory = try makeTemporaryDirectory()
        let explicitDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: selectedDirectory)
            try? FileManager.default.removeItem(at: explicitDirectory)
        }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        firstTab.currentDirectory = selectedDirectory.path

        workspace.newTab(startDirectory: explicitDirectory.path)
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertEqual(secondTab.currentDirectory, explicitDirectory.path)
        XCTAssertEqual(secondTab.launchConfiguration.localStartDirectory, explicitDirectory.path)
    }

    func testWorkspaceTracksRecentLocalQuickPaths() throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let storeDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        let previous = TerminalQuickPathStore._setTestDirectoryOverride(storeDirectory)
        defer { _ = TerminalQuickPathStore._setTestDirectoryOverride(previous) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let tab = try XCTUnwrap(workspace.selectedTab)

        tab.currentDirectory = firstDirectory.path
        tab.currentDirectory = firstDirectory.path
        tab.currentDirectory = secondDirectory.path

        XCTAssertEqual(Set(workspace.recentQuickPaths.map(\.path)), Set([firstDirectory.path, secondDirectory.path]))
        XCTAssertEqual(workspace.quickPathRecords.first { $0.path == firstDirectory.path }?.visitCount, 1)
        workspace.flushQuickPathRecordsForTests()
        XCTAssertEqual(Set(TerminalQuickPathStore.load().map(\.path)), Set([firstDirectory.path, secondDirectory.path]))
    }

    func testWorkspaceDoesNotTrackSSHQuickPaths() throws {
        let directory = try makeTemporaryDirectory()
        let storeDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        let previous = TerminalQuickPathStore._setTestDirectoryOverride(storeDirectory)
        defer { _ = TerminalQuickPathStore._setTestDirectoryOverride(previous) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        workspace.openSSH(profile: SSHConnectionProfile(host: "example.com"))
        let sshTab = try XCTUnwrap(workspace.selectedTab)

        sshTab.currentDirectory = directory.path

        XCTAssertTrue(workspace.quickPathRecords.isEmpty)
        XCTAssertTrue(TerminalQuickPathStore.load().isEmpty)
    }

    func testOpenQuickPathCreatesLocalTabAtDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let storeDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        let previous = TerminalQuickPathStore._setTestDirectoryOverride(storeDirectory)
        defer { _ = TerminalQuickPathStore._setTestDirectoryOverride(previous) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        workspace.openQuickPath(directory.path)
        let tab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertEqual(tab.currentDirectory, directory.path)
        XCTAssertEqual(tab.launchConfiguration.localStartDirectory, directory.path)
        XCTAssertEqual(workspace.quickPathRecords.first?.path, directory.path)
    }

    func testQuickPathStoreSortsFrequentPathsByVisitsThenRecency() throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let thirdDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
            try? FileManager.default.removeItem(at: thirdDirectory)
        }

        let records = [
            TerminalQuickPathRecord(path: firstDirectory.path, lastVisitedAt: Date(timeIntervalSince1970: 10), visitCount: 2),
            TerminalQuickPathRecord(path: secondDirectory.path, lastVisitedAt: Date(timeIntervalSince1970: 30), visitCount: 4),
            TerminalQuickPathRecord(path: thirdDirectory.path, lastVisitedAt: Date(timeIntervalSince1970: 20), visitCount: 4)
        ]

        XCTAssertEqual(
            TerminalQuickPathStore.frequent(records, limit: 3).map(\.path),
            [secondDirectory.path, thirdDirectory.path, firstDirectory.path]
        )
        XCTAssertEqual(
            TerminalQuickPathStore.recent(records, limit: 2).map(\.path),
            [secondDirectory.path, thirdDirectory.path]
        )
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

    func testClosingLastTabEmptiesWorkspaceAndNotifiesHost() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        var allTabsClosedCount = 0
        workspace.onAllTabsClosed = { allTabsClosedCount += 1 }
        XCTAssertNotNil(workspace.selectedTab)

        XCTAssertTrue(workspace.closeSelectedTab())

        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selectedTab)
        XCTAssertNil(workspace.selectedID)
        XCTAssertEqual(allTabsClosedCount, 1)
    }

    func testCancelledLastTabCloseDoesNotNotifyHost() throws {
        let confirmer = RecordingTabCloseConfirmer()
        confirmer.shouldAllowClose = false
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        var allTabsClosedCount = 0
        workspace.onAllTabsClosed = { allTabsClosedCount += 1 }

        XCTAssertFalse(workspace.closeSelectedTab())

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(allTabsClosedCount, 0)
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTerminalShortcutRecorderCoalescesInputUntilNewline() throws {
        let started = Date(timeIntervalSince1970: 200)
        let recorder = TerminalShortcutRecorder(startedAt: started)

        recorder.record(data: Array("g".utf8), echoEnabled: true, now: started.addingTimeInterval(0.1))
        recorder.record(data: Array("it ".utf8), echoEnabled: true, now: started.addingTimeInterval(0.2))
        recorder.record(data: Array("status\npwd\n".utf8), echoEnabled: true, now: started.addingTimeInterval(0.3))

        let shortcut = try XCTUnwrap(recorder.finish(title: "Shell", finishedAt: started.addingTimeInterval(1)))
        XCTAssertEqual(shortcut.events.count, 2)
        XCTAssertEqual(shortcut.events.map(\.requiresEchoOff), [false, false])
        XCTAssertEqual(String(bytes: shortcut.events[0].bytes, encoding: .utf8), "git status\n")
        XCTAssertEqual(String(bytes: shortcut.events[1].bytes, encoding: .utf8), "pwd\n")
    }

    func testTerminalShortcutJSONUsesEscapedTextAndStringBytes() throws {
        let event = TerminalShortcutEvent(delayMilliseconds: 25, bytes: Array("ls -la\n".utf8))
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["text"] as? String, "ls -la\\n")
        XCTAssertEqual(object["bytes"] as? String, "ls -la\\n")

        let decoded = try JSONDecoder().decode(TerminalShortcutEvent.self, from: data)
        XCTAssertEqual(decoded.bytes, Array("ls -la\n".utf8))
    }

    func testTerminalShortcutDecodesLegacyNumericBytes() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "delayMilliseconds": 0,
          "bytes": [108, 115, 10],
          "requiresEchoOff": false
        }
        """

        let decoded = try JSONDecoder().decode(TerminalShortcutEvent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bytes, Array("ls\n".utf8))
    }

    func testTerminalShortcutStorePersistsProtectedInputInVault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-shortcut-test-\(UUID().uuidString)", isDirectory: true)
        let previous = TerminalShortcutStore._setTestDirectoryOverride(directory)
        defer {
            _ = TerminalShortcutStore._setTestDirectoryOverride(previous)
            try? FileManager.default.removeItem(at: directory)
        }

        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Password",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            durationMilliseconds: 100,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: [],
                    requiresEchoOff: true,
                    transientProtectedBytes: Array("secret\n".utf8)
                )
            ],
            hasProtectedInput: true
        )

        TerminalShortcutStore.save([shortcut])
        let loaded = try XCTUnwrap(TerminalShortcutStore.load().first)
        var cache: [String: [UInt8]] = [:]

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("protected-vault.key").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("protected-vault.json").path))
        XCTAssertEqual(loaded.events.first?.resolvedBytes(cache: &cache), Array("secret\n".utf8))
    }
}
