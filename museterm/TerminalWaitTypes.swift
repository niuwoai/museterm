import Foundation

nonisolated enum TerminalWaitCondition: String, Codable { case commandFinished, agentState, attention, outputChanged, events }
nonisolated enum TerminalWaitOutcome: String, Codable {
    case matched, timeout, cancelled, targetClosed, targetReplaced, appExited, appRestarted, cursorExpired, futureCursor, disabled
}

nonisolated struct TerminalWaitSpec: Codable {
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
    nonisolated init(from decoder: Decoder) throws {
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

nonisolated struct TerminalWaitResult: Codable {
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

nonisolated enum TerminalWaitError: String, Error { case invalidSpec, duplicateID, capacityExceeded, unknownWait }

nonisolated struct TerminalWaitCommandSnapshot {
    let finished: Bool
    let state: TerminalCommandLifecycleState
}

nonisolated struct TerminalWaitTargetSnapshot {
    let agent: TerminalAgentSnapshot?
    let outputRevision: Int
    var commands: [UUID: TerminalWaitCommandSnapshot] = [:]
}
