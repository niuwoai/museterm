import Combine
import Foundation

/// Owns only adopted sessions. Preheated shells are registered when they become actual tabs.
final class TerminalSessionRegistry {
    let events: TerminalSessionEventStore
    lazy var attention: TerminalAttentionStore = {
        let store = TerminalAttentionStore(events: events)
        store.onUnreadChanged = { [weak self] id, unread in self?.sessions[id]?.updateUnreadAttention(unread) }
        return store
    }()
    lazy var waits = TerminalWaitCoordinator(registry: self)
    private(set) var agentMonitoringEnabled = true
    private(set) var sessions: [UUID: TerminalSession] = [:]
    private(set) var locations: [UUID: TerminalSessionLocation] = [:]

    init(events: TerminalSessionEventStore = TerminalSessionEventStore()) { self.events = events }

    func register(_ session: TerminalSession, location: TerminalSessionLocation = .mainWindow) {
        _ = attention
        if sessions[session.id] != nil {
            move(session.id, to: location)
            return
        }
        sessions[session.id] = session
        locations[session.id] = location
        session.eventStore = events
        session.attentionStore = attention
        session.onSessionClosed = { [weak self] id in self?.unregister(id) }
        events.publish(tabID: session.id, kind: .registered, location: location)
    }

    func move(_ id: UUID, to location: TerminalSessionLocation) {
        guard sessions[id] != nil, locations[id] != location else { return }
        locations[id] = location
        events.publish(tabID: id, kind: .locationChanged, location: location)
    }

    private func unregister(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        locations[id] = nil
        events.publish(tabID: id, kind: .closed)
        session.eventStore = nil
        session.onSessionClosed = nil
        session.attentionStore = nil
        session.updateUnreadAttention(false)
    }

    func refreshAgents(now: Date = Date()) {
        guard agentMonitoringEnabled else { return }
        for session in sessions.values { session.expireAgentStatus(now: now) }
    }

    func setAgentMonitoringEnabled(_ enabled: Bool) {
        guard enabled != agentMonitoringEnabled else { return }
        agentMonitoringEnabled = enabled
        if !enabled {
            for session in sessions.values { session.updateAgent { $0 = TerminalAgentMonitor() } }
            attention.clearAgents()
            waits.disableAgentWaits()
        }
    }

    var snapshots: [TerminalRegisteredSessionSnapshot] {
        sessions.values.sorted { $0.sequence < $1.sequence }.map {
            TerminalRegisteredSessionSnapshot(id: $0.id, location: locations[$0.id] ?? .mainWindow,
                                              agent: $0.agentStatus)
        }
    }
}
