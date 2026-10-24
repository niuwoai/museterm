import Foundation

extension TerminalWaitCoordinator {
    convenience init(registry: TerminalSessionRegistry) {
        self.init(events: registry.events, target: { [weak registry] id in
            guard let session = registry?.sessions[id] else { return nil }
            session.expireAgentStatus(now: Date())
            let commands = Dictionary(uniqueKeysWithValues: session.commandBlocks.map {
                ($0.id, TerminalWaitCommandSnapshot(finished: $0.endedAt != nil, state: $0.commandLifecycleState))
            })
            return TerminalWaitTargetSnapshot(agent: session.agentStatus,
                outputRevision: session.lastOutputRevision, commands: commands)
        }, attention: { [weak registry] in registry?.attention.activeItems ?? [] },
        monitoringEnabled: { [weak registry] in registry?.agentMonitoringEnabled == true })
    }
}
