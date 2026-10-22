import XCTest
@testable import museterm

@MainActor
final class TerminalAgentStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func report(_ grant: TerminalAgentGrant, sequence: UInt64 = 1,
                        activity: TerminalAgentActivity = .working,
                        block: TerminalAgentBlockReason? = nil,
                        result: TerminalAgentResult? = nil) -> TerminalAgentReport {
        TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
            sequence: sequence, activity: activity, blockReason: block, result: result)
    }

    func testBindingStartsUnknownAndNeverTakesInputLease() throws {
        let session = TerminalSession(sequence: 1)
        _ = try session.bindAgent(kind: .codex, now: now)
        XCTAssertEqual(session.agentStatus?.activity, .unknown)
        XCTAssertEqual(session.agentStatus?.reason, .bound)
        XCTAssertNil(session.aiLease)
        XCTAssertFalse(session.aiRequiresTakeover)
    }

    func testReportRepresentsQuestionAndCompletionSeparatelyFromIdle() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .claude, now: now)
        try monitor.report(report(grant, activity: .blocked, block: .question), now: now)
        XCTAssertEqual(monitor.snapshot?.blockReason, .question)
        try monitor.report(report(grant, sequence: 2, activity: .idle), now: now)
        XCTAssertNil(monitor.snapshot?.lastResult)
        XCTAssertNil(monitor.snapshot?.blockReason)
        try monitor.report(report(grant, sequence: 3, activity: .idle, result: .completed), now: now)
        XCTAssertEqual(monitor.snapshot?.lastResult, .completed)
    }

    func testOldBindingCannotOverwriteReplacement() throws {
        var monitor = TerminalAgentMonitor()
        let old = try monitor.bind(kind: .codex, now: now)
        let current = try monitor.bind(kind: .claude, now: now)
        XCTAssertThrowsError(try monitor.report(report(old), now: now))
        XCTAssertEqual(monitor.snapshot?.instanceID, current.instanceID)
        try monitor.report(report(current), now: now)
        XCTAssertEqual(monitor.snapshot?.activity, .working)
    }

    func testOutOfOrderAndDuplicateReportsLeaveStateUnchanged() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .codex, now: now)
        try monitor.report(report(grant, sequence: 4), now: now)
        let expected = monitor.snapshot
        for sequence: UInt64 in [4, 3, 0] {
            XCTAssertThrowsError(try monitor.report(report(grant, sequence: sequence, activity: .idle), now: now))
            XCTAssertEqual(monitor.snapshot, expected)
        }
    }

    func testInvalidBlockAndResultCombinationsAreRejected() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .codex, now: now)
        let invalid = [report(grant, activity: .blocked), report(grant, block: .approval),
                       report(grant, result: .completed)]
        for value in invalid {
            XCTAssertThrowsError(try monitor.report(value, now: now))
            XCTAssertEqual(monitor.snapshot?.reportSequence, 0)
        }
    }

    func testExpirationBecomesUnknownAndFreshReportRecovers() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .codex, now: now)
        try monitor.report(report(grant, activity: .blocked, block: .approval), now: now)
        monitor.expire(now: now.addingTimeInterval(119))
        XCTAssertEqual(monitor.snapshot?.activity, .blocked)
        monitor.expire(now: now.addingTimeInterval(120))
        XCTAssertEqual(monitor.snapshot?.activity, .unknown)
        XCTAssertEqual(monitor.snapshot?.reason, .expired)
        XCTAssertNil(monitor.snapshot?.lastResult)
        XCTAssertNil(monitor.snapshot?.blockReason)
        try monitor.report(report(grant, sequence: 2), now: now.addingTimeInterval(121))
        XCTAssertEqual(monitor.snapshot?.activity, .working)
    }

    func testScreenCannotOverrideBoundIntegrationEvenAfterExpiry() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .codex, now: now)
        try monitor.report(report(grant), now: now)
        monitor.expire(now: now.addingTimeInterval(121))
        monitor.observe(kind: .claude, runID: UUID(), source: .foregroundProcess,
                        screen: approval, now: now.addingTimeInterval(122))
        XCTAssertEqual(monitor.snapshot?.kind, .codex)
        XCTAssertEqual(monitor.snapshot?.reason, .expired)
    }

    func testExitRevokesCapabilityAndDoesNotInventSuccessfulResult() throws {
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .codex, now: now)
        monitor.exit(now: now)
        XCTAssertEqual(monitor.snapshot?.activity, .exited)
        XCTAssertEqual(monitor.snapshot?.lastResult, .unknown)
        XCTAssertThrowsError(try monitor.report(report(grant), now: now))
        monitor.exit(now: now, close: true)
        XCTAssertThrowsError(try monitor.bind(kind: .codex, now: now))
    }

    func testObservedCommandEndPreventsSameRunResurrection() {
        var monitor = TerminalAgentMonitor()
        let run = UUID()
        monitor.observe(kind: .codex, runID: run, source: .shellCommand, screen: nil, now: now)
        monitor.endObservedRun(run, now: now)
        monitor.observe(kind: .codex, runID: run, source: .foregroundProcess, screen: approval, now: now)
        XCTAssertEqual(monitor.snapshot?.activity, .exited)
        monitor.observe(kind: .codex, runID: UUID(), source: .foregroundProcess, screen: approval, now: now)
        XCTAssertEqual(monitor.snapshot?.activity, .blocked)
    }

    func testUnknownScreenAndLostForegroundNeverBecomeIdle() {
        var monitor = TerminalAgentMonitor()
        monitor.observe(kind: .claude, runID: UUID(), source: .foregroundProcess, screen: "Done!", now: now)
        XCTAssertEqual(monitor.snapshot?.activity, .unknown)
        monitor.foregroundLost(now: now)
        XCTAssertEqual(monitor.snapshot?.reason, .foregroundLost)
        XCTAssertNil(monitor.snapshot?.lastResult)
    }

    func testApprovalRuleRequiresCombinedLiveChoices() {
        XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .claude, screen: approval).activity, .blocked)
        for screen in ["Do you want to proceed?", "README: Do you want to proceed?\nYes\nNo", "thinking…", "done", "?"] {
            XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .claude, screen: screen).activity, .unknown)
        }
        let oldApproval = approval + String(repeating: "\nordinary output", count: 20)
        XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .claude, screen: oldApproval).activity, .unknown)
    }

    func testCommandIdentificationRejectsLogsPipelinesAndHelp() {
        XCTAssertEqual(TerminalAgentScreenRules.launchedKind(command: "/usr/local/bin/codex resume"), .codex)
        for command in ["echo codex", "cat README.md", "codex --help", "codex --version", "codex | tee log", "claude; echo done", "ssh host codex"] {
            XCTAssertNil(TerminalAgentScreenRules.launchedKind(command: command))
        }
    }

    func testSSHRequiresExplicitReportingInsteadOfLocalHeuristics() throws {
        let profile = SSHConnectionProfile(name: "fixture", host: "localhost", user: "fixture")
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        session.observeAgentLaunch(command: "codex", runID: UUID())
        session.observeAgentForeground(kind: .codex, processRunID: UUID(), screen: approval, now: now)
        XCTAssertNil(session.agentStatus)
        let grant = try session.bindAgent(kind: .codex, now: now)
        try session.reportAgent(report(grant), now: now)
        XCTAssertEqual(session.agentStatus?.activity, .working)
    }

    func testHeartbeatDoesNotFloodSemanticEventsOrLeakCapability() throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        let grant = try session.bindAgent(kind: .codex, now: now)
        try session.reportAgent(report(grant), now: now)
        let count = registry.events.events.count
        try session.reportAgent(report(grant, sequence: 2), now: now.addingTimeInterval(1))
        XCTAssertEqual(registry.events.events.count, count)
        XCTAssertEqual(session.agentStatus?.reportSequence, 2)
        let data = try JSONEncoder().encode(registry.events.events)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(grant.token))
    }

    func testBoundReporterIsRevokedWhenItsKnownCommandEnds() throws {
        let session = TerminalSession(sequence: 1)
        session.startShellIntegratedCommand(command: "codex", historySnapshot: "")
        let grant = try session.bindAgent(kind: .codex)
        try session.reportAgent(report(grant))
        session.finishActiveCommand(exitCode: 0, completionSource: .shellIntegration, historySnapshot: "")
        XCTAssertEqual(session.agentStatus?.activity, .exited)
        XCTAssertThrowsError(try session.reportAgent(report(grant, sequence: 2)))
    }

    func testBindingBeforeLaunchFollowsOnlyTheFirstKnownCommand() throws {
        let session = TerminalSession(sequence: 1)
        let grant = try session.bindAgent(kind: .codex)
        session.startShellIntegratedCommand(command: "codex", historySnapshot: "")
        try session.reportAgent(report(grant))
        session.startShellIntegratedCommand(command: "claude", historySnapshot: "")
        XCTAssertEqual(session.agentStatus?.kind, .claude)
        XCTAssertThrowsError(try session.reportAgent(report(grant, sequence: 2)))
    }

    private var approval: String { "Do you want to proceed?\n❯ 1. Yes\n2. No, and tell Claude what to do differently" }
}
