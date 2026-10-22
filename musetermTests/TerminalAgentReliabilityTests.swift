import XCTest
@testable import museterm

@MainActor
final class TerminalAgentReliabilityTests: XCTestCase {
    func testWaitLimitRejectsExcessAndCancellationReleasesCapacity() throws {
        let registry = TerminalSessionRegistry()
        let owner = UUID().uuidString
        let spec = TerminalWaitSpec(condition: .events, after: registry.events.cursor)
        for _ in 0..<TerminalWaitCoordinator.maximumPerOwner {
            try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        }
        XCTAssertThrowsError(try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec))
        registry.waits.cancelAll(owner: owner)
        XCTAssertEqual(registry.waits.pendingCount, 0)
        XCTAssertEqual(registry.waits.drainCompletions().count, TerminalWaitCoordinator.maximumPerOwner)
    }

    func testExpiredEventCursorFailsClosedAndZeroTimeoutDoesNotSubscribe() throws {
        let registry = TerminalSessionRegistry(events: TerminalSessionEventStore(capacity: 2))
        let start = registry.events.cursor
        for _ in 0..<3 { registry.events.publish(tabID: UUID(), kind: .outputChanged) }
        try registry.waits.begin(id: UUID().uuidString, owner: UUID().uuidString,
            spec: TerminalWaitSpec(condition: .events, after: start))
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .cursorExpired)
        try registry.waits.begin(id: UUID().uuidString, owner: UUID().uuidString,
            spec: TerminalWaitSpec(condition: .events, after: registry.events.cursor, timeoutSeconds: 0))
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .timeout)
        XCTAssertEqual(registry.waits.pendingCount, 0)
    }

    func testResponseRetentionRemovesAbandonedFilesButKeepsFreshReplies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-retention-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("abandoned.json")
        let fresh = root.appendingPathComponent("fresh.json")
        try Data().write(to: old)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-301)], ofItemAtPath: old.path)
        try TerminalToolResponseRetention.prune(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testApprovalRegressionCorpusDoesNotTurnLogsIntoCompletions() {
        let positives = ["Do you want to proceed?\n❯ 1. Yes\n2. No", "Would you like to run the following command?\n› 1. Yes, proceed (y)\n3. No, and tell Codex", "是否继续？\n❯ 1. 是\n2. 否"]
        let negatives = ["All done. Tests passed", "Do you want to proceed?", "README\n1. Yes\n2. No", "thinking…", "?", "❯ 1. Yes\n2. No", "Do you want to proceed?\n❯ 1. Yes", "是否继续？\n1. 是\n2. 否"]
        for kind: TerminalAgentKind in [.claude, .codex] {
            for text in positives { XCTAssertEqual(TerminalAgentScreenRules.detect(kind: kind, screen: text).blockReason, .approval) }
            for text in negatives { XCTAssertEqual(TerminalAgentScreenRules.detect(kind: kind, screen: text).activity, .unknown) }
            for text in positives {
                let scrolledAway = text + String(repeating: "\nordinary log", count: 20)
                XCTAssertEqual(TerminalAgentScreenRules.detect(kind: kind, screen: scrolledAway).activity, .unknown)
            }
        }
    }

    func testRegistryDeallocationReleasesSubscriptions() {
        let events = TerminalSessionEventStore()
        var registry: TerminalSessionRegistry? = TerminalSessionRegistry(events: events)
        registry?.register(TerminalSession(sequence: 1))
        _ = registry?.waits
        XCTAssertEqual(events.observerCount, 2)
        registry = nil
        XCTAssertEqual(events.observerCount, 0)
    }

    func testDisableDoesNotChangeOrdinaryCommandWaitAndNoInputIsAuthorized() throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        session.startShellIntegratedCommand(command: "printf ok", historySnapshot: "")
        let command = try XCTUnwrap(session.commandBlocks.last)
        try registry.waits.begin(id: UUID().uuidString, owner: UUID().uuidString,
            spec: TerminalWaitSpec(condition: .commandFinished, after: registry.events.cursor,
                tabID: session.id, commandID: command.id))
        registry.setAgentMonitoringEnabled(false)
        XCTAssertEqual(registry.waits.pendingCount, 1)
        session.finishActiveCommand(exitCode: 0, completionSource: .shellIntegration, historySnapshot: "")
        XCTAssertEqual(registry.waits.drainCompletions().first?.commandState, .succeeded)
        XCTAssertNil(session.aiLease)
    }
}
