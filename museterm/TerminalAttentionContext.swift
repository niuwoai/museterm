import Foundation

nonisolated struct TerminalAttentionTerminalContext: Codable, Equatable {
    enum Kind: String, Codable, Hashable { case bell, commandFinished, processExited }
    let kind: Kind
    let eventID: UUID
    let commandID: UUID?
    let exitCode: Int32?
    let failed: Bool
    var occurrences = 1

    var attentionKind: TerminalAttentionKind {
        switch kind {
        case .bell: return .bell
        case .commandFinished: return failed ? .commandFailed : .commandCompleted
        case .processExited: return .processExited
        }
    }

    init(kind: Kind, eventID: UUID, commandID: UUID?, exitCode: Int32?, failed: Bool) {
        self.kind = kind
        self.eventID = eventID
        self.commandID = commandID
        self.exitCode = exitCode
        self.failed = failed
    }
}

/// Retain deduplication after acknowledgement/eviction, bounded independently of the inbox.
nonisolated struct TerminalAttentionDeduplication {
    private struct Key: Hashable {
        let tabID: UUID
        let kind: TerminalAttentionTerminalContext.Kind
        let eventID: UUID
    }
    private let capacity = 1_024
    private var keys: Set<Key> = []
    private var order: [Key] = []

    func contains(tabID: UUID, context: TerminalAttentionTerminalContext) -> Bool {
        keys.contains(Key(tabID: tabID, kind: context.kind, eventID: context.eventID))
    }

    mutating func insert(tabID: UUID, context: TerminalAttentionTerminalContext) -> Bool {
        let key = Key(tabID: tabID, kind: context.kind, eventID: context.eventID)
        guard keys.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity { keys.remove(order.removeFirst()) }
        return true
    }

    mutating func remove(tabID: UUID) {
        order.removeAll { $0.tabID == tabID }
        keys = Set(order)
    }
}
