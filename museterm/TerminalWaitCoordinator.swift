import Foundation

enum TerminalWaitCondition: String, Codable { case commandFinished, agentState, attention, outputChanged, events }
enum TerminalWaitOutcome: String, Codable {
    case matched, timeout, cancelled, targetClosed, targetReplaced, appExited, appRestarted, cursorExpired, futureCursor, disabled
}

struct TerminalWaitSpec: Codable {
    let condition: TerminalWaitCondition
    let after: TerminalEventCursor
    var tabID: UUID? = nil
    var commandID: UUID? = nil
    var instanceID: UUID? = nil
    var runID: UUID? = nil
    var activity: TerminalAgentActivity? = nil
    var revision: Int? = nil
    var timeoutSeconds: Double = 30
}

extension TerminalWaitSpec {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(condition: try values.decode(TerminalWaitCondition.self, forKey: .condition),
            after: try values.decode(TerminalEventCursor.self, forKey: .after),
            tabID: try values.decodeIfPresent(UUID.self, forKey: .tabID),
            commandID: try values.decodeIfPresent(UUID.self, forKey: .commandID),
            instanceID: try values.decodeIfPresent(UUID.self, forKey: .instanceID),
            runID: try values.decodeIfPresent(UUID.self, forKey: .runID),
            activity: try values.decodeIfPresent(TerminalAgentActivity.self, forKey: .activity),
            revision: try values.decodeIfPresent(Int.self, forKey: .revision),
            timeoutSeconds: try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30)
    }
}

struct TerminalWaitResult: Codable {
    let waitID: String
    let outcome: TerminalWaitOutcome
    var cursor: TerminalEventCursor
    var event: TerminalSessionEvent? = nil
    var agent: TerminalAgentSnapshot? = nil
    var commandID: UUID? = nil
    var commandState: TerminalCommandLifecycleState? = nil
    var attention: TerminalAttentionItem? = nil
    var revision: Int? = nil
}

enum TerminalWaitError: String, Error { case invalidSpec, duplicateID, capacityExceeded, unknownWait }

/// One main-actor transaction checks the condition and installs the waiter. No check/subscribe gap.
final class TerminalWaitCoordinator {
    struct Pending {
        let id: String
        let owner: String
        let spec: TerminalWaitSpec
        let deadline: Date
    }
    private weak var registry: TerminalSessionRegistry?
    private let events: TerminalSessionEventStore
    private var observation: UUID?
    private var pending: [String: Pending] = [:]
    private var earlyCancellations: [String: (owner: String, date: Date)] = [:]
    private var closedOwners: [String: Date] = [:]
    private(set) var completions: [TerminalWaitResult] = []
    static let maximumWaiters = 128
    static let maximumPerOwner = 16
    static let maximumTimeout: Double = 60

    init(registry: TerminalSessionRegistry) {
        self.registry = registry
        events = registry.events
        observation = registry.events.observe { [weak self] in self?.observe($0) }
    }

    deinit { if let observation { events.removeObserver(observation) } }
    var pendingCount: Int { pending.count }

    func begin(id: String, owner: String, spec: TerminalWaitSpec, now: Date = Date()) throws {
        try validate(id: id, owner: owner, spec: spec)
        guard pending[id] == nil, !completions.contains(where: { $0.waitID == id }) else { throw TerminalWaitError.duplicateID }
        guard pending.count + completions.count < Self.maximumWaiters,
              pending.values.filter({ $0.owner == owner }).count < Self.maximumPerOwner else {
            throw TerminalWaitError.capacityExceeded
        }
        let waiter = Pending(id: id, owner: owner, spec: spec, deadline: now.addingTimeInterval(spec.timeoutSeconds))
        if earlyCancellations[id]?.owner == owner || closedOwners[owner] != nil {
            earlyCancellations[id] = nil
            complete(waiter, outcome: .cancelled)
        } else if let result = evaluate(waiter) { completions.append(result) }
        else if spec.timeoutSeconds == 0 { complete(waiter, outcome: .timeout) }
        else { pending[id] = waiter }
    }

    @discardableResult
    func cancel(id: String, owner: String) -> Bool {
        guard UUID(uuidString: id) != nil, UUID(uuidString: owner) != nil else { return false }
        guard let waiter = pending[id] else {
            if earlyCancellations.count < Self.maximumWaiters { earlyCancellations[id] = (owner, Date()) }
            return false
        }
        guard waiter.owner == owner else { return false }
        complete(waiter, outcome: .cancelled)
        return true
    }

    func cancelAll(owner: String) {
        if UUID(uuidString: owner) != nil, closedOwners.count < Self.maximumWaiters { closedOwners[owner] = Date() }
        for waiter in Array(pending.values) where waiter.owner == owner { complete(waiter, outcome: .cancelled) }
    }

    func disableAgentWaits() {
        for waiter in Array(pending.values) where [.agentState, .attention].contains(waiter.spec.condition) {
            complete(waiter, outcome: .disabled)
        }
    }

    func expire(now: Date = Date()) {
        earlyCancellations = earlyCancellations.filter { now.timeIntervalSince($0.value.date) <= Self.maximumTimeout }
        closedOwners = closedOwners.filter { now.timeIntervalSince($0.value) <= Self.maximumTimeout }
        for waiter in Array(pending.values) where now >= waiter.deadline { complete(waiter, outcome: .timeout) }
    }

    func drainCompletions() -> [TerminalWaitResult] {
        let ready = completions
        completions.removeAll(keepingCapacity: true)
        return ready
    }

    private func validate(id: String, owner: String, spec: TerminalWaitSpec) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: owner) != nil,
              spec.timeoutSeconds.isFinite, (0...Self.maximumTimeout).contains(spec.timeoutSeconds),
              spec.condition == .events || spec.tabID != nil else { throw TerminalWaitError.invalidSpec }
        switch spec.condition {
        case .commandFinished: guard spec.commandID != nil else { throw TerminalWaitError.invalidSpec }
        case .agentState:
            guard spec.instanceID != nil, spec.runID != nil, spec.activity != nil else { throw TerminalWaitError.invalidSpec }
        case .outputChanged: guard let revision = spec.revision, revision >= 0 else { throw TerminalWaitError.invalidSpec }
        default: break
        }
    }

    private func observe(_ event: TerminalSessionEvent) {
        for waiter in Array(pending.values) where waiter.spec.tabID == nil || waiter.spec.tabID == event.tabID {
            if event.occurredAt >= waiter.deadline { complete(waiter, outcome: .timeout) }
            else if event.kind == .closed && waiter.spec.tabID == event.tabID { complete(waiter, outcome: .targetClosed) }
            else if let result = evaluate(waiter) {
                pending[waiter.id] = nil
                completions.append(result)
            }
        }
    }

    private func evaluate(_ waiter: Pending) -> TerminalWaitResult? {
        guard let registry else { return nil }
        let spec = waiter.spec
        let store = registry.events
        guard spec.after.appEpoch == store.appEpoch else { return result(waiter, .appRestarted) }
        guard spec.after.sequence <= store.sequence else { return result(waiter, .futureCursor) }
        if [.agentState, .attention].contains(spec.condition), !registry.agentMonitoringEnabled { return result(waiter, .disabled) }
        let session = spec.tabID.flatMap { registry.sessions[$0] }
        if spec.tabID != nil, session == nil { return result(waiter, .targetClosed) }
        switch spec.condition {
        case .commandFinished:
            guard let block = session?.commandBlocks.first(where: { $0.id == spec.commandID }) else {
                return result(waiter, .targetReplaced)
            }
            guard block.endedAt != nil else { return nil }
            var matched = result(waiter, .matched)
            matched.commandID = block.id
            matched.commandState = block.commandLifecycleState
            return matched
        case .agentState:
            session?.expireAgentStatus(now: Date())
            guard let state = session?.agentStatus else { return result(waiter, .targetReplaced) }
            guard state.instanceID == spec.instanceID, state.runID == spec.runID else { return result(waiter, .targetReplaced) }
            guard state.activity == spec.activity else { return nil }
            var matched = result(waiter, .matched)
            matched.agent = state
            return matched
        case .outputChanged:
            guard let current = session?.lastOutputRevision, current > (spec.revision ?? 0) else { return nil }
            var matched = result(waiter, .matched)
            matched.revision = current
            return matched
        case .attention, .events:
            do {
                let batch = try store.read(after: spec.after, limit: 1_024)
                if spec.condition == .attention {
                    guard let item = registry.attention.activeItems.first(where: {
                        $0.createdSequence > spec.after.sequence && (spec.tabID == nil || $0.tabID == spec.tabID)
                    }) else { return nil }
                    var matched = result(waiter, .matched)
                    matched.attention = item
                    matched.cursor = TerminalEventCursor(appEpoch: store.appEpoch, sequence: item.createdSequence)
                    return matched
                }
                let match = batch.events.first {
                    (spec.tabID == nil || $0.tabID == spec.tabID) && (spec.condition == .events || $0.kind == .attentionCreated)
                }
                guard let match else { return nil }
                var matched = result(waiter, .matched)
                matched.cursor = match.cursor
                matched.event = match
                matched.attention = match.attention
                return matched
            } catch let error as TerminalEventReadError {
                return result(waiter, error == .cursorExpired ? .cursorExpired : error == .appRestarted ? .appRestarted : .futureCursor)
            } catch { return result(waiter, .cursorExpired) }
        }
    }

    private func result(_ waiter: Pending, _ outcome: TerminalWaitOutcome) -> TerminalWaitResult {
        TerminalWaitResult(waitID: waiter.id, outcome: outcome,
            cursor: registry?.events.cursor ?? waiter.spec.after)
    }

    private func complete(_ waiter: Pending, outcome: TerminalWaitOutcome) {
        pending[waiter.id] = nil
        completions.append(result(waiter, outcome))
    }
}
