import XCTest
@testable import museterm

@MainActor
final class TerminalAttentionStoreTests: XCTestCase {
    private func fixture() throws -> (TerminalSessionRegistry, TerminalSession, TerminalAgentGrant) {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        return (registry, session, try session.bindAgent(kind: .codex))
    }

    private func report(_ session: TerminalSession, _ grant: TerminalAgentGrant, _ sequence: UInt64,
                        _ activity: TerminalAgentActivity, block: TerminalAgentBlockReason? = nil,
                        result: TerminalAgentResult? = nil) throws {
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: sequence, activity: activity, blockReason: block, result: result))
    }

    func testViewingQuestionMarksReadWithoutResolvingAndHeartbeatDoesNotDuplicate() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .question)
        let item = try XCTUnwrap(registry.attention.activeItems.first)
        registry.attention.markViewed(tabID: session.id)
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertNotNil(registry.attention.activeItems.first?.readAt)
        try report(session, grant, 2, .blocked, block: .question)
        XCTAssertEqual(registry.attention.activeItems.first?.id, item.id)
        try report(session, grant, 3, .working)
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
    }

    func testExpiredQuestionRemainsVisibleAndRecoversWithoutDuplication() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .approval)
        let item = try XCTUnwrap(registry.attention.activeItems.first)
        session.expireAgentStatus(now: Date().addingTimeInterval(121))
        XCTAssertEqual(registry.attention.activeItems.first?.isStale, true)
        try report(session, grant, 2, .blocked, block: .approval)
        XCTAssertEqual(registry.attention.activeItems.first?.id, item.id)
        XCTAssertEqual(registry.attention.activeItems.first?.isStale, false)
    }

    func testOldAcknowledgementCannotReadNewEpisode() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .question)
        let old = try XCTUnwrap(registry.attention.activeItems.first)
        try report(session, grant, 2, .working)
        try report(session, grant, 3, .blocked, block: .question)
        let new = try XCTUnwrap(registry.attention.activeItems.first)
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertThrowsError(try registry.attention.markRead(id: old.id, version: old.version))
        XCTAssertNil(registry.attention.activeItems.first?.readAt)
        try registry.attention.markRead(id: new.id, version: new.version)
        XCTAssertThrowsError(try registry.attention.markRead(id: new.id, version: new.version))
    }

    func testCompletionSummaryClearsOnViewAndIdleDoesNotCreateSuccess() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .idle)
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        try report(session, grant, 2, .idle, result: .completed)
        XCTAssertEqual(registry.attention.activeItems.first?.kind, .completed)
        registry.attention.markViewed(tabID: session.id)
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        try report(session, grant, 3, .working)
        try report(session, grant, 4, .idle, result: .failed)
        XCTAssertEqual(registry.attention.activeItems.first?.kind, .failed)
    }

    func testReplacementAndClosedDetachedSessionResolveOldQuestions() throws {
        let (registry, session, grant) = try fixture()
        registry.move(session.id, to: .detached)
        try report(session, grant, 1, .blocked, block: .approval)
        let replacement = try session.bindAgent(kind: .claude)
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        try report(session, replacement, 1, .blocked, block: .question)
        session.terminate()
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
    }

    func testPriorityPutsQuestionsAheadOfResultSummaries() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .idle, result: .completed)
        let other = TerminalSession(sequence: 2)
        registry.register(other)
        let second = try other.bindAgent(kind: .claude)
        try report(other, second, 1, .blocked, block: .question)
        XCTAssertEqual(registry.attention.activeItems.map(\.kind), [.question, .completed])
    }

    func testDisabledMonitoringClearsStatesWithoutGrantingOrChangingInputControl() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .question)
        registry.setAgentMonitoringEnabled(false)
        XCTAssertNil(session.agentStatus)
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        XCTAssertNil(session.aiLease)
        registry.setAgentMonitoringEnabled(true)
        XCTAssertThrowsError(try report(session, grant, 2, .working))
        session.startShellIntegratedCommand(command: "printf ok", historySnapshot: "")
        XCTAssertEqual(session.commandBlocks.count, 1)
    }

    func testNotificationPreferenceDoesNotControlItemCreation() throws {
        let name = "attention-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.notificationsEnabled = false
        preferences.notifyAgentAttention = false
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .question)
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertFalse(TerminalPreferences(defaults: defaults).notifyAgentAttention)
    }

    func testStaleNotificationNavigationDoesNotReadNewerItemVersion() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        let grant = try session.bindAgent(kind: .codex)
        try report(session, grant, 1, .blocked, block: .question)
        let old = try XCTUnwrap(workspace.sessionRegistry.attention.activeItems.first)
        session.expireAgentStatus(now: Date().addingTimeInterval(121))
        workspace.newTab()
        XCTAssertTrue(workspace.focusAttention(tabID: session.id, itemID: old.id, version: old.version))
        XCTAssertNil(workspace.sessionRegistry.attention.activeItems.first?.readAt)
    }

    func testNotificationRouteRejectsMalformedIdentityInsteadOfAcknowledgingAll() {
        let tab = UUID().uuidString, item = UUID().uuidString
        XCTAssertNotNil(TerminalNotificationRoute(tab: tab, item: item, version: 1))
        XCTAssertNotNil(TerminalNotificationRoute(tab: tab, item: nil, version: nil))
        XCTAssertNil(TerminalNotificationRoute(tab: tab, item: "invalid", version: 1))
        XCTAssertNil(TerminalNotificationRoute(tab: tab, item: item, version: nil))
        XCTAssertNil(TerminalNotificationRoute(tab: "invalid", item: nil, version: nil))
    }

    func testAcknowledgementToolRequiresPairingAndExactVersion() throws {
        let (registry, session, grant) = try fixture()
        try report(session, grant, 1, .blocked, block: .question)
        let item = try XCTUnwrap(registry.attention.activeItems.first)
        let json: [String: Any] = ["id": UUID().uuidString, "action": "acknowledge_attention",
            "attentionID": item.id.uuidString, "attentionVersion": item.version]
        let request = try JSONDecoder().decode(TerminalToolRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(TerminalAttentionToolService.perform(request, registry: registry, snapshotSequence: 1, paired: { false }).ok)
        XCTAssertNil(registry.attention.activeItems.first?.readAt)
        XCTAssertTrue(TerminalAttentionToolService.perform(request, registry: registry, snapshotSequence: 1, paired: { true }).ok)
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertNotNil(registry.attention.activeItems.first?.readAt)
        XCTAssertFalse(TerminalAttentionToolService.perform(request, registry: registry, snapshotSequence: 1, paired: { true }).ok)
    }
}
