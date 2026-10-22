import Combine
import Foundation

enum TerminalAttentionKind: String, Codable {
    case approval, question, blocked, completed, failed
    var requiresAnswer: Bool { self == .approval || self == .question || self == .blocked }
}

struct TerminalAttentionItem: Codable, Equatable, Identifiable {
    let id: UUID
    let tabID: UUID
    let instanceID: UUID
    let runID: UUID
    let kind: TerminalAttentionKind
    let createdAt: Date
    let createdSequence: UInt64
    let source: TerminalAgentSource
    let confidence: TerminalAgentConfidence
    var version: Int = 1
    var readAt: Date? = nil
    var resolvedAt: Date? = nil
    var isStale = false
}

enum TerminalAttentionMutationError: String, Error { case notFound, staleVersion }

/// Read state never determines whether an Agent still needs an answer. No terminal text is stored.
final class TerminalAttentionStore: ObservableObject {
    @Published private(set) var items: [TerminalAttentionItem] = []
    private let events: TerminalSessionEventStore
    private var observation: UUID?
    private var previous: [UUID: TerminalAgentSnapshot] = [:]
    private let capacity = 256

    init(events: TerminalSessionEventStore) {
        self.events = events
        observation = events.observe { [weak self] in self?.consume($0) }
    }

    deinit { if let observation { events.removeObserver(observation) } }

    var activeItems: [TerminalAttentionItem] {
        items.filter { $0.resolvedAt == nil }.sorted {
            if $0.kind.requiresAnswer != $1.kind.requiresAnswer { return $0.kind.requiresAnswer }
            if ($0.readAt == nil) != ($1.readAt == nil) { return $0.readAt == nil }
            return $0.createdSequence < $1.createdSequence
        }
    }

    func markRead(id: UUID, version: Int, now: Date = Date()) throws {
        guard let index = items.firstIndex(where: { $0.id == id && $0.resolvedAt == nil }) else {
            throw TerminalAttentionMutationError.notFound
        }
        guard items[index].version == version else { throw TerminalAttentionMutationError.staleVersion }
        guard items[index].readAt == nil else { return }
        items[index].readAt = now
        items[index].version += 1
        if !items[index].kind.requiresAnswer { items[index].resolvedAt = now }
        emit(items[index].resolvedAt == nil ? .attentionUpdated : .attentionResolved, items[index])
    }

    func markViewed(tabID: UUID, now: Date = Date()) {
        for item in activeItems where item.tabID == tabID {
            try? markRead(id: item.id, version: item.version, now: now)
        }
    }

    func clear(now: Date = Date()) {
        for index in items.indices where items[index].resolvedAt == nil { resolve(index, now: now) }
        previous.removeAll()
    }

    private func consume(_ event: TerminalSessionEvent) {
        if event.kind == .closed {
            for index in items.indices where items[index].tabID == event.tabID && items[index].resolvedAt == nil {
                resolve(index, now: event.occurredAt)
            }
            previous[event.tabID] = nil
            return
        }
        guard event.kind == .agentChanged else { return }
        guard let state = event.agent else {
            for index in items.indices where items[index].tabID == event.tabID && items[index].resolvedAt == nil {
                resolve(index, now: event.occurredAt)
            }
            previous[event.tabID] = nil
            return
        }
        let old = previous[event.tabID]
        previous[event.tabID] = state
        updateExisting(tabID: event.tabID, state: state, now: event.occurredAt)
        if state.activity == .blocked {
            let kind: TerminalAttentionKind = state.blockReason == .approval ? .approval : state.blockReason == .question ? .question : .blocked
            createIfNeeded(tabID: event.tabID, state: state, kind: kind, now: event.occurredAt)
        } else if state.source == .integration, state.reason == .reported,
                  state.activity == .idle || state.activity == .exited,
                  old?.lastResult != state.lastResult || old?.instanceID != state.instanceID {
            if state.lastResult == .completed || state.lastResult == .failed {
                createIfNeeded(tabID: event.tabID, state: state,
                    kind: state.lastResult == .completed ? .completed : .failed, now: event.occurredAt)
            }
        }
    }

    private func updateExisting(tabID: UUID, state: TerminalAgentSnapshot, now: Date) {
        for index in items.indices where items[index].tabID == tabID && items[index].resolvedAt == nil {
            let item = items[index]
            let sameRun = item.instanceID == state.instanceID && item.runID == state.runID
            let sameBlock = item.kind == .approval ? state.blockReason == .approval : item.kind == .question ? state.blockReason == .question : state.blockReason == .other
            if !sameRun || (!item.kind.requiresAnswer && state.activity == .working)
                || (item.kind.requiresAnswer && state.activity != .unknown && (state.activity != .blocked || !sameBlock)) {
                resolve(index, now: now)
            } else if item.kind.requiresAnswer, item.isStale != (state.activity == .unknown) {
                items[index].isStale = state.activity == .unknown
                items[index].version += 1
                emit(.attentionUpdated, items[index])
            }
        }
    }

    private func createIfNeeded(tabID: UUID, state: TerminalAgentSnapshot, kind: TerminalAttentionKind, now: Date) {
        guard !items.contains(where: { $0.tabID == tabID && $0.instanceID == state.instanceID && $0.runID == state.runID && $0.kind == kind && $0.resolvedAt == nil }) else { return }
        // Prefer discarding resolved history, then read summaries. Active questions are never dropped.
        if items.count >= capacity, let index = items.firstIndex(where: { $0.resolvedAt != nil || !$0.kind.requiresAnswer }) {
            items.remove(at: index)
        }
        guard items.count < capacity || kind.requiresAnswer else { return }
        let item = TerminalAttentionItem(id: UUID(), tabID: tabID, instanceID: state.instanceID,
            runID: state.runID, kind: kind, createdAt: now, createdSequence: events.sequence + 1,
            source: state.source, confidence: state.confidence)
        items.append(item)
        emit(.attentionCreated, item)
    }

    private func resolve(_ index: Int, now: Date) {
        items[index].resolvedAt = now
        items[index].version += 1
        emit(.attentionResolved, items[index])
    }

    private func emit(_ kind: TerminalSessionEventKind, _ item: TerminalAttentionItem) {
        events.publish(tabID: item.tabID, kind: kind, attention: item)
    }
}
