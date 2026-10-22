import Combine
import Foundation

enum TerminalSessionEventKind: String, Codable {
    case registered, locationChanged, closed, processExited
    case commandStarted, commandFinished, outputChanged, controlChanged, agentChanged
    case attentionCreated, attentionUpdated, attentionResolved
}

struct TerminalEventCursor: Codable, Equatable {
    let appEpoch: UUID
    let sequence: UInt64
}

/// Metadata only: terminal text, commands and reporting capabilities never enter the journal.
struct TerminalSessionEvent: Codable, Equatable {
    let cursor: TerminalEventCursor
    let tabID: UUID
    let kind: TerminalSessionEventKind
    let occurredAt: Date
    var commandID: UUID? = nil
    var commandState: TerminalCommandLifecycleState? = nil
    var revision: Int? = nil
    var agent: TerminalAgentSnapshot? = nil
    var location: TerminalSessionLocation? = nil
    var attention: TerminalAttentionItem? = nil
}

enum TerminalEventReadError: Error, Equatable {
    case appRestarted, cursorExpired, futureCursor
}

struct TerminalEventBatch: Codable {
    let events: [TerminalSessionEvent]
    let nextCursor: TerminalEventCursor
    let hasMore: Bool
}

/// Accessed on the main actor, alongside sessions. A bounded replay log, not a work queue.
final class TerminalSessionEventStore {
    let appEpoch: UUID
    private let capacity: Int
    private(set) var sequence: UInt64 = 0
    private(set) var events: [TerminalSessionEvent] = []
    private var observers: [UUID: (TerminalSessionEvent) -> Void] = [:]
    private var pendingDelivery: [TerminalSessionEvent] = []
    private var isDelivering = false

    init(capacity: Int = 1_024, appEpoch: UUID = UUID()) {
        self.capacity = max(1, capacity)
        self.appEpoch = appEpoch
    }

    var cursor: TerminalEventCursor { TerminalEventCursor(appEpoch: appEpoch, sequence: sequence) }
    var observerCount: Int { observers.count }

    func publish(tabID: UUID, kind: TerminalSessionEventKind, now: Date = Date(),
                 commandID: UUID? = nil, commandState: TerminalCommandLifecycleState? = nil,
                 revision: Int? = nil, agent: TerminalAgentSnapshot? = nil,
                 location: TerminalSessionLocation? = nil, attention: TerminalAttentionItem? = nil) {
        sequence += 1
        let event = TerminalSessionEvent(cursor: cursor, tabID: tabID, kind: kind, occurredAt: now,
            commandID: commandID, commandState: commandState, revision: revision,
            agent: agent, location: location, attention: attention)
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        pendingDelivery.append(event)
        // A callback may publish another event. Preserve the same order for every observer.
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pendingDelivery.isEmpty {
            let next = pendingDelivery.removeFirst()
            for callback in Array(observers.values) { callback(next) }
        }
    }

    @discardableResult
    func observe(_ callback: @escaping (TerminalSessionEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func read(after cursor: TerminalEventCursor, limit: Int = 100) throws -> TerminalEventBatch {
        guard cursor.appEpoch == appEpoch else { throw TerminalEventReadError.appRestarted }
        guard cursor.sequence <= sequence else { throw TerminalEventReadError.futureCursor }
        let oldest = events.first?.cursor.sequence ?? (sequence + 1)
        guard cursor.sequence >= oldest - 1 else { throw TerminalEventReadError.cursorExpired }
        let matching = events.filter { $0.cursor.sequence > cursor.sequence }
        let page = Array(matching.prefix(max(1, min(limit, capacity))))
        return TerminalEventBatch(events: page, nextCursor: page.last?.cursor ?? cursor,
                                  hasMore: matching.count > page.count)
    }
}

enum TerminalSessionLocation: String, Codable { case mainWindow, detached }

struct TerminalRegisteredSessionSnapshot: Codable {
    let id: UUID
    let location: TerminalSessionLocation
    let agent: TerminalAgentSnapshot?
}

/// Owns only adopted sessions. Preheated shells are registered when they become actual tabs.
final class TerminalSessionRegistry {
    let events: TerminalSessionEventStore
    lazy var attention = TerminalAttentionStore(events: events)
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
            attention.clear()
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
