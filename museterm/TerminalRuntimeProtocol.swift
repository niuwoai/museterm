import Foundation

nonisolated enum TerminalRuntimeLimits {
    static let protocolVersion = 3
    static let defaultColumns = 80
    static let defaultRows = 24
    static let restartExitedFeature = "restart_exited_v1"
    static let agentToolsFeature = "agent_tools_v1"
    static let eventWaitFeature = "event_wait_v1"
    static let commandLifecycleFeature = "command_lifecycle_v1"
    static let terminalAttentionFeature = "terminal_attention_v1"
    static let maximumFrameBytes = 131_072
    // Requests stay small; 64 session projections include bounded command,
    // Agent and escaped path metadata, independently of PTY output chunks.
    static let maximumResponseBytes = 1_048_576
    static let maximumOutputBytes = 65_536
    static let maximumSessions = 64
    static let maximumClients = 32
    static let maximumClientQueueBytes = maximumResponseBytes * 2
    static let requestDeadline: TimeInterval = 5
    static let leaseSeconds: TimeInterval = 120
    static let subscriptionHeartbeat: TimeInterval = 15
    // AppKit tracking and clipboard operations can temporarily pause the view.
    // RPC latency and a bounded output consumer require different deadlines.
    static let subscriptionWriteDeadline: TimeInterval = 30
    static let defaultConsumerAcknowledgementDeadline: TimeInterval = 30
    #if DEBUG
    /// Tests shorten this so a stuck parse can be observed without a 30 second wait.
    nonisolated(unsafe) static var consumerAcknowledgementDeadlineOverride: TimeInterval?
    #endif
    static var consumerAcknowledgementDeadline: TimeInterval {
        #if DEBUG
        consumerAcknowledgementDeadlineOverride ?? defaultConsumerAcknowledgementDeadline
        #else
        defaultConsumerAcknowledgementDeadline
        #endif
    }
}

nonisolated enum TerminalRuntimeAction: String, Codable {
    case hello, create, list, read, subscribe, inspectInput, input, resize, close, restartExited
    case acquireControl, renewControl, releaseControl
    case listAttention, acknowledgeAttention, readEvents
    case shutdownIfEmpty, diagnostics
    case bindAgent, reportAgent, getAgentState
    case configureReminders
}

nonisolated enum TerminalRuntimeInputSource: String, Codable { case human, ai, protocolReply }

nonisolated struct TerminalRuntimeLaunch: Codable, Equatable {
    let executable: String
    var arguments: [String] = []
    var executableName: String? = nil
    var environment: [String: String] = [:]
    let directory: String
    var columns: Int = TerminalRuntimeLimits.defaultColumns
    var rows: Int = TerminalRuntimeLimits.defaultRows
    var reminderPolicy: TerminalReminderPolicy? = nil
}

nonisolated struct TerminalRuntimeSessionInfo: Codable {
    let id: UUID
    let revision: UInt64
    let pid: Int32
    let generation: UUID
    let controlEpoch: UUID
    let directory: String
    let running: Bool
    let exitStatus: Int32?
    let columns: Int
    let rows: Int
    let outputOffset: UInt64
    let controlOwner: String?
    let nextInputSequence: UInt64
    let agent: TerminalAgentSnapshot?
    var controlExpiresAt: Date? = nil
    var outputRevision: Int? = nil
    var commands: [TerminalRuntimeCommandInfo]? = nil
    var reminderPolicy: TerminalReminderPolicy? = nil
}

nonisolated struct TerminalRuntimeRequest: Codable {
    var protocolVersion = TerminalRuntimeLimits.protocolVersion
    var id = UUID()
    let action: TerminalRuntimeAction
    var capability: String? = nil
    var sessionID: UUID? = nil
    var generation: UUID? = nil
    var controlEpoch: UUID? = nil
    var launch: TerminalRuntimeLaunch? = nil
    var after: TerminalRuntimeOutputCursor? = nil
    var data: Data? = nil
    var columns: Int? = nil
    var rows: Int? = nil
    var owner: String? = nil
    var source: TerminalRuntimeInputSource? = nil
    var inputSequence: UInt64? = nil
    var expectedEchoEnabled: Bool? = nil
    var expectedForegroundPID: Int32? = nil
    var attentionID: UUID? = nil
    var attentionVersion: Int? = nil
    var reminderPolicy: TerminalReminderPolicy? = nil
    var eventAfter: TerminalEventCursor? = nil
    var eventLimit: Int? = nil
    var agentKind: TerminalAgentKind? = nil
    var agentReport: TerminalAgentReport? = nil
    var commandID: UUID? = nil
}

nonisolated struct TerminalRuntimeResponse: Codable {
    var protocolVersion = TerminalRuntimeLimits.protocolVersion
    var version = AppVersion.value
    let serviceEpoch: UUID
    let id: UUID
    let action: TerminalRuntimeAction
    var ok = true
    var error: String? = nil
    var session: TerminalRuntimeSessionInfo? = nil
    var sessions: [TerminalRuntimeSessionInfo]? = nil
    var data: Data? = nil
    var cursor: TerminalRuntimeOutputCursor? = nil
    var latestOffset: UInt64? = nil
    var hasGap: Bool? = nil
    var echoEnabled: Bool? = nil
    var foregroundPID: Int32? = nil
    var attention: [TerminalAttentionItem]? = nil
    var events: TerminalEventBatch? = nil
    var eventHead: TerminalEventCursor? = nil
    var disconnects: [TerminalRuntimeDisconnectDiagnostic]? = nil
    var features: [String]? = nil
    var agentGrant: TerminalAgentGrant? = nil
    var pendingWaits: Int? = nil

    func encodedTransportFrame(using encoder: JSONEncoder) throws -> Data {
        var bytes = try encoder.encode(self)
        if bytes.count > TerminalRuntimeLimits.maximumResponseBytes {
            var rejected = TerminalRuntimeResponse(serviceEpoch: serviceEpoch, id: id, action: action)
            rejected.ok = false
            rejected.error = "response_too_large"
            bytes = try encoder.encode(rejected)
        }
        bytes.append(0x0A)
        return bytes
    }
}

/// Bounded transport metadata only. Never retain request bodies or capabilities.
nonisolated struct TerminalRuntimeDisconnectDiagnostic: Codable {
    let reason: String
    let lastAction: TerminalRuntimeAction?
    let subscribed: Bool
    let queuedBytes: Int
    let idleSeconds: TimeInterval
}
