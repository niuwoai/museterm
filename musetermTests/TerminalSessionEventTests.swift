import XCTest
@testable import museterm

@MainActor
final class TerminalSessionEventTests: XCTestCase {
    func testReplayIsBoundedAndPaginatedForIndependentReaders() throws {
        let store = TerminalSessionEventStore(capacity: 3)
        let start = store.cursor
        for _ in 0..<3 { store.publish(tabID: UUID(), kind: .registered) }
        let first = try store.read(after: start, limit: 2)
        XCTAssertEqual(first.events.map(\.cursor.sequence), [1, 2])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(try store.read(after: first.nextCursor).events.map(\.cursor.sequence), [3])
        XCTAssertEqual(try store.read(after: start).events.count, 3)
        store.publish(tabID: UUID(), kind: .closed)
        XCTAssertEqual(store.events.count, 3)
        XCTAssertThrowsError(try store.read(after: start)) { XCTAssertEqual($0 as? TerminalEventReadError, .cursorExpired) }
        XCTAssertEqual(try store.read(after: TerminalEventCursor(appEpoch: store.appEpoch, sequence: 1)).events.count, 3)
    }

    func testEpochAndFutureCursorAreDistinctFailures() {
        let store = TerminalSessionEventStore()
        XCTAssertThrowsError(try store.read(after: TerminalEventCursor(appEpoch: UUID(), sequence: 0))) {
            XCTAssertEqual($0 as? TerminalEventReadError, .appRestarted)
        }
        XCTAssertThrowsError(try store.read(after: TerminalEventCursor(appEpoch: store.appEpoch, sequence: 1))) {
            XCTAssertEqual($0 as? TerminalEventReadError, .futureCursor)
        }
    }

    func testObserversReceiveNestedEventsInOrderAndCanUnsubscribe() {
        let store = TerminalSessionEventStore()
        var first: [UInt64] = []
        var second: [UInt64] = []
        let one = store.observe { event in
            first.append(event.cursor.sequence)
            if event.cursor.sequence == 1 { store.publish(tabID: event.tabID, kind: .closed) }
        }
        let two = store.observe { second.append($0.cursor.sequence) }
        store.publish(tabID: UUID(), kind: .registered)
        XCTAssertEqual(first, [1, 2])
        XCTAssertEqual(second, [1, 2])
        store.removeObserver(one)
        store.removeObserver(two)
        XCTAssertEqual(store.observerCount, 0)
        store.publish(tabID: UUID(), kind: .closed)
        XCTAssertEqual(first, [1, 2])
    }

    func testDetachReattachKeepsOneRegisteredSessionAndExactUUIDLookup() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let tab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let original = workspace.sessionRegistry.sessions.count
        _ = workspace.detachTab(tab)
        XCTAssertEqual(workspace.sessionRegistry.sessions.count, original)
        XCTAssertEqual(workspace.sessionRegistry.locations[tab.id], .detached)
        XCTAssertTrue(try workspace.toolTab(matching: tab.id.uuidString) === tab)
        XCTAssertTrue(workspace.reattachTab(tab))
        XCTAssertEqual(workspace.sessionRegistry.locations[tab.id], .mainWindow)
        XCTAssertEqual(workspace.sessionRegistry.events.events.filter { $0.tabID == tab.id && $0.kind == .registered }.count, 1)
    }

    func testDetachedTerminationRemovesSessionExactlyOnce() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let tab = try XCTUnwrap(workspace.selectedTab)
        _ = workspace.detachTab(tab)
        tab.terminate()
        tab.terminate()
        XCTAssertNil(workspace.sessionRegistry.sessions[tab.id])
        XCTAssertNil(workspace.sessionRegistry.locations[tab.id])
        XCTAssertEqual(workspace.sessionRegistry.events.events.filter { $0.tabID == tab.id && $0.kind == .closed }.count, 1)
        XCTAssertThrowsError(try workspace.toolTab(matching: tab.id.uuidString))
    }

    func testRegistrationExcludesUnadoptedPreheatedSessions() {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let unused = TerminalSession(sequence: 100)
        unused.observeAgentLaunch(command: "codex", runID: UUID())
        XCTAssertEqual(workspace.sessionRegistry.sessions.count, 1)
        XCTAssertNil(unused.eventStore)
    }

    func testCommandsAndProcessExitProduceMetadataEvents() throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        session.startShellIntegratedCommand(command: "codex", historySnapshot: "")
        let block = try XCTUnwrap(session.commandBlocks.last)
        XCTAssertEqual(session.agentStatus?.runID, block.id)
        session.finishActiveCommand(exitCode: 0, completionSource: .shellIntegration, historySnapshot: "")
        let finished = try XCTUnwrap(registry.events.events.last { $0.kind == .commandFinished })
        XCTAssertEqual(finished.commandID, block.id)
        XCTAssertEqual(finished.commandState, .succeeded)
        XCTAssertEqual(session.agentStatus?.lastResult, .unknown)
        session.state = .exited(0)
        session.state = .exited(0)
        XCTAssertEqual(registry.events.events.filter { $0.kind == .processExited }.count, 1)
        let text = String(decoding: try JSONEncoder().encode(registry.events.events), as: UTF8.self)
        XCTAssertFalse(text.contains("command\":"))
        XCTAssertFalse(text.contains("history"))
    }
}
