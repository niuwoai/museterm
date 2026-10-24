import Foundation

extension TerminalAgentSnapshot {
    var label: String {
        L10n.format("agent.status.label", L10n.string("agent.kind.\(kind.rawValue)"),
                    L10n.string("agent.activity.\(activity.rawValue)"))
    }

    var detail: String {
        L10n.format("agent.status.detail", label, L10n.string("agent.source.\(source.rawValue)"),
                    L10n.string("agent.confidence.\(confidence.rawValue)"),
                    L10n.string("agent.reason.\(reason.rawValue)"))
    }
}

extension TerminalSession {
    func observedAgentCommandID(kind: TerminalAgentKind) -> UUID? {
        guard let block = commandBlocks.last, block.endedAt == nil,
              block.commandStartSource == .shellIntegration,
              TerminalAgentScreenRules.launchedKind(command: block.command) == kind else { return nil }
        return block.id
    }
    func bindAgent(kind: TerminalAgentKind, now: Date = Date()) throws -> TerminalAgentGrant {
        guard case .running = state else { throw TerminalAgentReportError.unavailable }
        let commandID = observedAgentCommandID(kind: kind)
        return try updateAgent { try $0.bind(kind: kind, commandID: commandID, now: now) }
    }

    func reportAgent(_ report: TerminalAgentReport, now: Date = Date()) throws {
        guard case .running = state else { throw TerminalAgentReportError.unavailable }
        try updateAgent { try $0.report(report, now: now) }
    }

    func expireAgentStatus(now: Date) {
        guard !runtimeOwnsAgent else { return }
        updateAgent { $0.expire(now: now) }
    }

    func observeAgentLaunch(command: String, runID: UUID) {
        guard !runtimeOwnsAgent else { return }
        // SSH command text is not proof of the identity of a remote foreground process.
        guard case .localShell = launchConfiguration,
              let kind = TerminalAgentScreenRules.launchedKind(command: command) else { return }
        updateAgent { $0.observe(kind: kind, runID: runID, source: .shellCommand, screen: nil, now: Date()) }
    }

    func observeAgentForeground(kind: TerminalAgentKind?, processRunID: UUID, screen: String, now: Date) {
        guard !runtimeOwnsAgent else { return }
        guard case .localShell = launchConfiguration else { return }
        updateAgent {
            guard let kind else { $0.foregroundLost(now: now); return }
            $0.observe(kind: kind, runID: processRunID, source: .foregroundProcess, screen: screen, now: now)
        }
    }
}
