import Foundation

struct TerminalAttentionTerminalContext: Codable, Equatable {
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

    init(event: TerminalAttentionEventKind, processRunID: UUID) {
        switch event {
        case .bell:
            self.init(kind: .bell, eventID: processRunID, commandID: nil, exitCode: nil, failed: false)
        case .commandFinished(let block):
            self.init(kind: .commandFinished, eventID: block.id, commandID: block.id,
                exitCode: block.exitCode, failed: block.commandLifecycleState == .failed)
        case .processExited(let code):
            self.init(kind: .processExited, eventID: processRunID, commandID: nil, exitCode: code, failed: code != nil && code != 0)
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
struct TerminalAttentionDeduplication {
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

extension TerminalAttentionStore {
    /// Eligibility determines inbox content; system notification permission only controls delivery.
    func recordTerminal(_ event: TerminalAttentionEventKind, session: TerminalSession,
                        input: TerminalNotificationPolicyInput) -> TerminalAttentionItem? {
        guard session.attentionStore === self, TerminalNotificationPolicy.isEligible(input),
              let item = recordTerminal(TerminalAttentionTerminalContext(event: event,
                processRunID: session.processRunID), tabID: session.id) else { return nil }
        if input.appIsActive && input.tabIsSelected {
            // Do not acknowledge an unrelated Agent question in the same terminal.
            try? markRead(id: item.id, version: item.version)
        }
        return item
    }
}
