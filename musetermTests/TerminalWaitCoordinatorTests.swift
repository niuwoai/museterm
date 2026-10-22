import XCTest
@testable import museterm

@MainActor
final class TerminalWaitCoordinatorTests: XCTestCase {
    private let owner = UUID().uuidString
    private func fixture() -> (TerminalSessionRegistry, TerminalSession) {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        return (registry, session)
    }

    func testCommandWaitReturnsExactFailureAndImmediateCompletion() throws {
        let (registry, session) = fixture()
        session.startShellIntegratedCommand(command: "false", historySnapshot: "")
        let command = try XCTUnwrap(session.commandBlocks.last)
        let spec = TerminalWaitSpec(condition: .commandFinished, after: registry.events.cursor,
            tabID: session.id, commandID: command.id)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        XCTAssertEqual(registry.waits.pendingCount, 1)
        session.finishActiveCommand(exitCode: 1, completionSource: .shellIntegration, historySnapshot: "")
        let result = try XCTUnwrap(registry.waits.drainCompletions().first)
        XCTAssertEqual(result.outcome, .matched)
        XCTAssertEqual(result.commandState, .failed)
        XCTAssertEqual(result.commandID, command.id)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .matched)
    }

    func testIndependentConsumersReadSameEventAndCursorDoesNotSkipNextEvent() throws {
        let (registry, session) = fixture()
        let start = registry.events.cursor
        registry.events.publish(tabID: session.id, kind: .outputChanged, revision: 1)
        registry.events.publish(tabID: session.id, kind: .outputChanged, revision: 2)
        let spec = TerminalWaitSpec(condition: .events, after: start, tabID: session.id)
        for _ in 0..<2 { try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec) }
        let result = registry.waits.drainCompletions()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].event?.cursor, result[1].event?.cursor)
        XCTAssertEqual(result[0].cursor.sequence, start.sequence + 1)
    }

    func testAgentIdentityReplacementAndDisableAreExplicitOutcomes() throws {
        let (registry, session) = fixture()
        let grant = try session.bindAgent(kind: .codex)
        let spec = TerminalWaitSpec(condition: .agentState, after: registry.events.cursor, tabID: session.id,
            instanceID: grant.instanceID, runID: grant.runID, activity: .working)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        _ = try session.bindAgent(kind: .codex)
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .targetReplaced)
        let state = try XCTUnwrap(session.agentStatus)
        let next = TerminalWaitSpec(condition: .agentState, after: registry.events.cursor, tabID: session.id,
            instanceID: state.instanceID, runID: state.runID, activity: .working)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: next)
        registry.setAgentMonitoringEnabled(false)
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .disabled)
    }

    func testOutputWaitFiltersTabsAndClosureTerminatesPendingWait() throws {
        let (registry, session) = fixture()
        let other = TerminalSession(sequence: 2)
        registry.register(other)
        let spec = TerminalWaitSpec(condition: .outputChanged, after: registry.events.cursor,
            tabID: session.id, revision: 0)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        other.recordOutputRevision(2)
        XCTAssertEqual(registry.waits.pendingCount, 1)
        session.recordOutputRevision(1)
        XCTAssertEqual(registry.waits.drainCompletions().first?.revision, 1)
        let closing = TerminalWaitSpec(condition: .outputChanged, after: registry.events.cursor,
            tabID: session.id, revision: 1)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: closing)
        session.terminate()
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .targetClosed)
    }

    func testCancellationIsOwnerBoundAndCanArriveBeforeWaitFile() throws {
        let (registry, session) = fixture()
        let spec = TerminalWaitSpec(condition: .outputChanged, after: registry.events.cursor,
            tabID: session.id, revision: 0)
        let id = UUID().uuidString
        try registry.waits.begin(id: id, owner: owner, spec: spec)
        XCTAssertFalse(registry.waits.cancel(id: id, owner: UUID().uuidString))
        XCTAssertEqual(registry.waits.pendingCount, 1)
        XCTAssertTrue(registry.waits.cancel(id: id, owner: owner))
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .cancelled)
        let early = UUID().uuidString
        _ = registry.waits.cancel(id: early, owner: owner)
        try registry.waits.begin(id: early, owner: owner, spec: spec)
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .cancelled)
    }

    func testTimeoutAndEpochErrorsAreNotSuccessfulMatches() throws {
        let (registry, session) = fixture()
        let now = Date()
        var spec = TerminalWaitSpec(condition: .outputChanged, after: registry.events.cursor,
            tabID: session.id, revision: 0, timeoutSeconds: 1)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec, now: now)
        registry.waits.expire(now: now.addingTimeInterval(1))
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .timeout)
        spec = TerminalWaitSpec(condition: .events, after: TerminalEventCursor(appEpoch: UUID(), sequence: 0))
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .appRestarted)
    }

    func testNewAttentionIsCapturedWithoutPollingOrInputLease() throws {
        let (registry, session) = fixture()
        let grant = try session.bindAgent(kind: .codex)
        let spec = TerminalWaitSpec(condition: .attention, after: registry.events.cursor, tabID: session.id)
        try registry.waits.begin(id: UUID().uuidString, owner: owner, spec: spec)
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .blocked, blockReason: .approval))
        XCTAssertEqual(registry.waits.drainCompletions().first?.attention?.kind, .approval)
        XCTAssertNil(session.aiLease)
    }

    func testHighOutputKeepsWaitersAndJournalBounded() throws {
        let (registry, session) = fixture()
        session.startShellIntegratedCommand(command: "sleep 10", historySnapshot: "")
        let command = try XCTUnwrap(session.commandBlocks.last)
        let spec = TerminalWaitSpec(condition: .commandFinished, after: registry.events.cursor,
            tabID: session.id, commandID: command.id)
        let observers = registry.events.observerCount
        for _ in 0..<64 { try registry.waits.begin(id: UUID().uuidString, owner: UUID().uuidString, spec: spec) }
        for revision in 1...2_000 { session.recordOutputRevision(revision) }
        XCTAssertEqual(registry.waits.pendingCount, 64)
        XCTAssertEqual(registry.events.events.count, 1_024)
        session.finishActiveCommand(exitCode: 0, completionSource: .shellIntegration, historySnapshot: "")
        XCTAssertEqual(registry.waits.drainCompletions().count, 64)
        XCTAssertEqual(registry.waits.pendingCount, 0)
        XCTAssertEqual(registry.events.observerCount, observers + 1)
    }

    func testAlreadyResolvedAttentionDoesNotMatchNewPendingCondition() throws {
        let (registry, session) = fixture()
        let grant = try session.bindAgent(kind: .codex)
        let cursor = registry.events.cursor
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .blocked, blockReason: .question))
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 2, activity: .working))
        try registry.waits.begin(id: UUID().uuidString, owner: owner,
            spec: TerminalWaitSpec(condition: .attention, after: cursor, tabID: session.id, timeoutSeconds: 0))
        XCTAssertEqual(registry.waits.drainCompletions().first?.outcome, .timeout)
    }

    func testWireSpecDefaultsTimeoutAndRejectsMissingCommandIdentity() throws {
        let registry = TerminalSessionRegistry()
        let data = try JSONSerialization.data(withJSONObject: ["condition": "events", "after": ["appEpoch": registry.events.appEpoch.uuidString, "sequence": 0]])
        let spec = try JSONDecoder().decode(TerminalWaitSpec.self, from: data)
        XCTAssertEqual(spec.timeoutSeconds, 30)
        XCTAssertThrowsError(try registry.waits.begin(id: UUID().uuidString, owner: owner,
            spec: TerminalWaitSpec(condition: .commandFinished, after: registry.events.cursor, tabID: UUID())))
    }
}
