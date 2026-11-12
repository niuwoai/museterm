import XCTest
@testable import museterm

@MainActor
final class TerminalOrdinaryAttentionTests: XCTestCase {
    private func fixture() -> (TerminalSessionRegistry, TerminalSession) {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        return (registry, session)
    }

    private func input(_ event: TerminalAttentionEventKind, selected: Bool = false,
                       enabled: Bool = true, active: Bool = true,
                       aiControlled: Bool = false) -> TerminalNotificationPolicyInput {
        TerminalNotificationPolicyInput(event: event, appIsActive: active, tabIsSelected: selected,
            aiControlled: aiControlled,
            notificationsEnabled: enabled, showInactiveTabBadges: true, notifyBells: true,
            notifyCommandFailures: true, notifyLongCommandCompletion: true, notifyProcessExits: true,
            longCommandThresholdSeconds: 10, failureMinimumDurationSeconds: 1)
    }

    private func command(id: UUID = UUID(), exitCode: Int32 = 0) -> TerminalCommandBlock {
        let end = Date()
        return TerminalCommandBlock(id: id, command: "build private-input", startedAt: end.addingTimeInterval(-20),
            endedAt: end, exitCode: exitCode, outputTail: "private-output", outputCharacterCount: 14,
            isInteractive: false, commandStartSource: .shellIntegration, completionSource: .shellIntegration)
    }

    func testAIControlSuppressesBackgroundCompletionButKeepsFailureAndBell() throws {
        let (registry, session) = fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-ai-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try session.takeAIControl(owner: "agent", archiveDirectory: directory)
        defer { session.releaseAIControl(reason: "test_finished") }

        let completed = command()
        let completion = input(.commandFinished(completed), active: false, aiControlled: true)
        XCTAssertNotNil(registry.attention.recordTerminal(.commandFinished(completed), session: session, input: completion))
        XCTAssertEqual(TerminalNotificationPolicy.delivery(for: completion), .none)

        let failed = command(exitCode: 1)
        let failure = input(.commandFinished(failed), active: false, aiControlled: true)
        XCTAssertEqual(TerminalNotificationPolicy.delivery(for: failure), .systemNotification(markTabBadge: true))

        let bell = input(.bell, active: false, aiControlled: true)
        XCTAssertEqual(TerminalNotificationPolicy.delivery(for: bell), .systemNotification(markTabBadge: true))

        session.releaseAIControl(reason: "human_unlock")
        let afterUnlock = command()
        let humanCompletion = input(.commandFinished(afterUnlock), active: false)
        XCTAssertEqual(TerminalNotificationPolicy.delivery(for: humanCompletion), .systemNotification(markTabBadge: true))
    }

    func testBellCreatesOneUnreadItemAndMergesRepeatedBells() throws {
        let (registry, session) = fixture()
        let first = try XCTUnwrap(registry.attention.recordTerminal(.bell, session: session, input: input(.bell)))
        let next = try XCTUnwrap(registry.attention.recordTerminal(.bell, session: session, input: input(.bell)))
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertTrue(session.hasUnreadAttention)
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(next.terminal?.occurrences, 2)
        XCTAssertGreaterThan(next.version, first.version)
        XCTAssertThrowsError(try registry.attention.markRead(id: first.id, version: first.version))
        XCTAssertTrue(session.hasUnreadAttention)
        session.clearUnreadAttention()
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        XCTAssertFalse(session.hasUnreadAttention)
        let later = try XCTUnwrap(registry.attention.recordTerminal(.bell, session: session, input: input(.bell)))
        XCTAssertNotEqual(first.id, later.id)
        XCTAssertTrue(session.hasUnreadAttention)
    }

    func testCommandCallbacksDeduplicateBeforeAndAfterAcknowledgement() throws {
        let (registry, session) = fixture()
        let event = TerminalAttentionEventKind.commandFinished(command())
        XCTAssertNotNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        XCTAssertNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        session.clearUnreadAttention()
        XCTAssertNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        XCTAssertFalse(session.hasUnreadAttention)
    }

    func testDifferentCommandIDsWithIdenticalTextAreNotMerged() {
        let (registry, session) = fixture()
        for _ in 0..<2 {
            let event = TerminalAttentionEventKind.commandFinished(command())
            _ = registry.attention.recordTerminal(event, session: session, input: input(event))
        }
        XCTAssertEqual(registry.attention.activeItems.count, 2)
    }

    func testProcessExitDeduplicatesUntilNewProcessGeneration() {
        let (registry, session) = fixture()
        let event = TerminalAttentionEventKind.processExited(0)
        _ = registry.attention.recordTerminal(event, session: session, input: input(event))
        session.clearUnreadAttention()
        XCTAssertNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        let oldRun = session.processRunID
        session.state = .exited(0)
        session.beginProcessRun()
        session.state = .running
        XCTAssertNotEqual(session.processRunID, oldRun)
        XCTAssertNotNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertTrue(session.hasUnreadAttention)
    }

    func testNotificationMasterSwitchDoesNotHideInboxItems() {
        let (registry, session) = fixture()
        let policy = input(.bell, enabled: false)
        XCTAssertEqual(TerminalNotificationPolicy.delivery(for: policy), .none)
        XCTAssertNotNil(registry.attention.recordTerminal(.bell, session: session, input: policy))
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        XCTAssertTrue(session.hasUnreadAttention)
    }

    func testSessionReporterRoutesOrdinaryBellIntoUnifiedStore() throws {
        let name = "ordinary-coordinator-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.notificationsEnabled = false
        preferences.notifyTerminalBell = true
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        TerminalNotificationCoordinator.shared.attach(workspace: workspace, preferences: preferences)
        original.reportBellAttention()
        original.reportBellAttention()
        XCTAssertEqual(workspace.sessionRegistry.attention.activeItems.count, 1)
        XCTAssertEqual(workspace.sessionRegistry.attention.activeItems.first?.terminal?.occurrences, 2)
        XCTAssertTrue(original.hasUnreadAttention)
        workspace.select(original)
        XCTAssertTrue(workspace.sessionRegistry.attention.activeItems.isEmpty)
        XCTAssertFalse(original.hasUnreadAttention)
    }

    func testOldAgentItemWithoutTerminalContextStillDecodes() throws {
        let item = TerminalAttentionItem(id: UUID(), tabID: UUID(), instanceID: UUID(), runID: UUID(),
            kind: .question, createdAt: Date(), createdSequence: 1, source: .integration, confidence: .high)
        let data = try JSONEncoder().encode(item)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("terminal"))
        XCTAssertEqual(try JSONDecoder().decode(TerminalAttentionItem.self, from: data), item)
    }

    func testDisabledCategoryAndShortCommandsDoNotCreateItems() {
        let (registry, session) = fixture()
        var policy = input(.bell)
        policy.notifyBells = false
        XCTAssertNil(registry.attention.recordTerminal(.bell, session: session, input: policy))
        var short = command()
        short.startedAt = short.endedAt!
        let event = TerminalAttentionEventKind.commandFinished(short)
        XCTAssertNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
        XCTAssertFalse(session.hasUnreadAttention)
    }

    func testForegroundReminderDoesNotAcknowledgeAgentQuestion() throws {
        let (registry, session) = fixture()
        let grant = try session.bindAgent(kind: .codex)
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .blocked, blockReason: .question))
        _ = registry.attention.recordTerminal(.bell, session: session, input: input(.bell, selected: true))
        XCTAssertEqual(registry.attention.activeItems.map(\.kind), [.question])
        XCTAssertNil(registry.attention.activeItems.first?.readAt)
        XCTAssertTrue(session.hasUnreadAttention)
    }

    func testDisablingAgentMonitoringPreservesOrdinaryReminder() throws {
        let (registry, session) = fixture()
        let grant = try session.bindAgent(kind: .codex)
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .blocked, blockReason: .question))
        _ = registry.attention.recordTerminal(.bell, session: session, input: input(.bell))
        registry.setAgentMonitoringEnabled(false)
        XCTAssertEqual(registry.attention.activeItems.map(\.kind), [.bell])
        XCTAssertTrue(session.hasUnreadAttention)
    }

    func testDetachedReminderResolvesOnSessionClose() {
        let (registry, session) = fixture()
        _ = registry.attention.recordTerminal(.bell, session: session, input: input(.bell))
        registry.move(session.id, to: .detached)
        XCTAssertEqual(registry.attention.activeItems.count, 1)
        session.terminate()
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
        XCTAssertFalse(session.hasUnreadAttention)
        XCTAssertNil(registry.attention.recordTerminal(.processExited(0), session: session, input: input(.processExited(0))))
        XCTAssertTrue(registry.attention.activeItems.isEmpty)
    }

    func testEvictionClearsBadgeAndRetainsCommandDeduplication() {
        let (registry, session) = fixture()
        let event = TerminalAttentionEventKind.commandFinished(command())
        _ = registry.attention.recordTerminal(event, session: session, input: input(event))
        let other = TerminalSession(sequence: 2)
        registry.register(other)
        for _ in 0..<registry.attention.capacity {
            let another = TerminalAttentionEventKind.commandFinished(command())
            _ = registry.attention.recordTerminal(another, session: other, input: input(another))
        }
        XCTAssertEqual(registry.attention.activeItems.count, registry.attention.capacity)
        XCTAssertFalse(session.hasUnreadAttention)
        XCTAssertTrue(other.hasUnreadAttention)
        XCTAssertNil(registry.attention.recordTerminal(event, session: session, input: input(event)))
    }

    func testMetadataContainsNoCommandOrTerminalTextAndRoundTrips() throws {
        let (registry, session) = fixture()
        let event = TerminalAttentionEventKind.commandFinished(command(exitCode: 1))
        let item = try XCTUnwrap(registry.attention.recordTerminal(event, session: session, input: input(event)))
        XCTAssertEqual(item.kind, .commandFailed)
        XCTAssertFalse(item.isAgent)
        XCTAssertNil(item.source)
        let data = try JSONEncoder().encode(item)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private-input"))
        XCTAssertFalse(text.contains("private-output"))
        XCTAssertEqual(try JSONDecoder().decode(TerminalAttentionItem.self, from: data), item)
    }

    func testBoundedDeduplicationCacheAndPerSessionCleanup() {
        var cache = TerminalAttentionDeduplication()
        let tab = UUID()
        let other = UUID()
        let context = TerminalAttentionTerminalContext(event: .processExited(0), processRunID: UUID())
        XCTAssertTrue(cache.insert(tabID: tab, context: context))
        XCTAssertTrue(cache.insert(tabID: other, context: context))
        cache.remove(tabID: tab)
        XCTAssertTrue(cache.insert(tabID: tab, context: context))
        XCTAssertFalse(cache.insert(tabID: other, context: context))
        for _ in 0..<1_024 {
            _ = cache.insert(tabID: tab, context: TerminalAttentionTerminalContext(event: .processExited(0), processRunID: UUID()))
        }
        XCTAssertTrue(cache.insert(tabID: other, context: context))
    }
}
