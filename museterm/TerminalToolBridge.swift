import Foundation

struct TerminalToolPaths {
    static let supportDirectoryName = "MuseTerm/Tools"
    static let stateFileName = "state.json"
    static let requestDirectoryName = "requests"
    static let responseDirectoryName = "responses"

    static var isIsolatedTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing-agent-state")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundleIdentifier?.hasPrefix("im.some.museterm.goaltests") == true
        #else
        false
        #endif
    }

    static var rootDirectory: URL {
        #if DEBUG
        if isIsolatedTesting {
            let path = ProcessInfo.processInfo.environment["MUSETERM_AGENT_TEST_TOOL_ROOT"]
            return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("museterm-agent-ui-\(ProcessInfo.processInfo.processIdentifier)")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return MuseTermLegacyCompatibility.directory("Tools", base: base)
    }

    static var stateFile: URL {
        rootDirectory.appendingPathComponent(stateFileName)
    }

    static var requestDirectory: URL {
        rootDirectory.appendingPathComponent(requestDirectoryName, isDirectory: true)
    }

    static var responseDirectory: URL {
        rootDirectory.appendingPathComponent(responseDirectoryName, isDirectory: true)
    }

    static func ensureDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
        for directory in [rootDirectory, requestDirectory, responseDirectory] {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

struct TerminalToolState: Codable {
    var projectLayout: TerminalProjectLayout? = nil
    var attentionItems: [TerminalAttentionItem]? = nil
    var capabilities: [String]? = nil
    var eventCursor: TerminalEventCursor? = nil
    var sessions: [TerminalRegisteredSessionSnapshot]? = nil
    let schemaVersion: Int
    let app: String
    let version: String
    let snapshotSequence: Int
    let updatedAt: Date
    let selectedTabID: String?
    let sessionTunnelPresets: [SessionTunnelPreset]
    let tabs: [TerminalToolTabSnapshot]

    init(
        schemaVersion: Int = 1,
        app: String,
        version: String,
        snapshotSequence: Int = 0,
        updatedAt: Date,
        selectedTabID: String?,
        sessionTunnelPresets: [SessionTunnelPreset] = [],
        tabs: [TerminalToolTabSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.version = version
        self.snapshotSequence = snapshotSequence
        self.updatedAt = updatedAt
        self.selectedTabID = selectedTabID
        self.sessionTunnelPresets = sessionTunnelPresets
        self.tabs = tabs
    }
}

struct TerminalToolTabSnapshot: Codable, Equatable {
    var agent: TerminalAgentSnapshot? = nil
    var runtime: TerminalToolRuntimeSnapshot? = nil
    var aiControlled: Bool? = nil
    var aiLeaseExpiresAt: Date? = nil
    var aiRequiresTakeover: Bool? = nil
    let id: String
    let index: Int
    let title: String
    let subtitle: String?
    let currentDirectory: String?
    let shellName: String?
    let sessionTunnelStatus: TerminalToolSessionTunnelSnapshot?
    let isSelected: Bool
    let state: String
    let columns: Int
    let rows: Int
    let screen: String
    let history: String
    let commandDiagnostics: TerminalToolCommandDiagnosticsSnapshot
    let commandBlocks: [TerminalToolCommandBlockSnapshot]
    let updatedAt: Date
}

struct TerminalToolRuntimeSnapshot: Codable, Equatable {
    let pid: Int32
    let generation: UUID
    let connected: Bool
    var errorCode: String? = nil
    var errorStage: String? = nil
    var attachOnly: Bool? = nil
    var eventCursor: TerminalEventCursor? = nil
    var outputRevision: Int? = nil
    var commands: [TerminalRuntimeCommandInfo]? = nil
}

struct TerminalToolSessionTunnelSnapshot: Codable, Equatable {
    let phase: String
    let name: String
    let localEndpoint: String
    let remoteEndpoint: String
    let targetHost: String
    let targetPort: Int
    let localPort: Int
    let startedAt: Date?
    let uploadedBytes: Int64
    let downloadedBytes: Int64
    let totalTransferredBytes: Int64
    let clientCount: Int
    let clients: [TerminalToolSessionTunnelClientSnapshot]
    let errorMessage: String?
    let occupiesTerminal: Bool

    init(status: SessionTunnelStatus) {
        phase = status.phase.rawValue
        name = status.configuration.displayName
        localEndpoint = status.configuration.localEndpoint
        remoteEndpoint = status.configuration.remoteEndpoint
        targetHost = status.configuration.targetHost
        targetPort = status.configuration.targetPort
        localPort = status.configuration.localPort
        startedAt = status.startedAt
        uploadedBytes = status.uploadedBytes
        downloadedBytes = status.downloadedBytes
        totalTransferredBytes = status.totalTransferredBytes
        clientCount = status.clients.count
        clients = status.clients.map(TerminalToolSessionTunnelClientSnapshot.init(client:))
        errorMessage = status.errorMessage
        occupiesTerminal = status.occupiesTerminal
    }
}

struct TerminalToolSessionTunnelClientSnapshot: Codable, Equatable {
    let id: UInt32
    let endpoint: String
    let connectedAt: Date
    let uploadedBytes: Int64
    let downloadedBytes: Int64

    nonisolated init(client: SessionTunnelClientSnapshot) {
        id = client.id
        endpoint = client.endpoint
        connectedAt = client.connectedAt
        uploadedBytes = client.uploadedBytes
        downloadedBytes = client.downloadedBytes
    }
}

struct TerminalToolCommandDiagnosticsSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let failedCommandCount: Int
    let diagnosticPriorityScore: Int
    let diagnosticPriorityFactors: [String]
    let diagnosticSeverity: String
    let diagnosticCategory: String
    let diagnosticCategoryEvidence: String?
    let diagnosticCategoryConfidence: String
    let latestFailedCommandID: String?
    let latestFailedCommand: String?
    let latestFailedWorkingDirectory: String?
    let latestFailedExitCode: Int?
    let latestFailedDurationMilliseconds: Int?
    let latestFailedCommandLifecycleState: String?
    let latestFailedCommandRiskLevel: String?
    let latestFailedCommandRiskReasons: [String]
    let latestFailedCommandStartSource: String?
    let latestFailedCompletionSource: String?
    let latestFailedCommandBoundaryConfidence: String?
    let latestFailedCommandBoundaryReasons: [String]
    let recentFailureCommandID: String?
    let recentFailureWorkingDirectory: String?
    let recentFailureDiagnostic: String?
    let recentFailureFingerprint: String?
    let recentFailureOutputTailLineNumber: Int?
    let recentFailureOutputTailLineText: String?
    let repeatedFailureDiagnostic: TerminalToolRepeatedFailureSnapshot?
    let suggestedNextInspection: String?
    let suggestedNextCommand: String?
    let suggestedNextAction: TerminalToolDiagnosticActionSnapshot?

    init(schemaVersion: Int = 1, diagnostics: CommandBlockDiagnostics) {
        self.schemaVersion = schemaVersion
        failedCommandCount = diagnostics.failedCommandCount
        diagnosticPriorityScore = diagnostics.diagnosticPriorityScore
        diagnosticPriorityFactors = diagnostics.diagnosticPriorityFactors.map(\.rawValue)
        diagnosticSeverity = diagnostics.diagnosticSeverity.rawValue
        diagnosticCategory = diagnostics.diagnosticCategory.rawValue
        diagnosticCategoryEvidence = diagnostics.diagnosticCategoryEvidence
        diagnosticCategoryConfidence = diagnostics.diagnosticCategoryConfidence.rawValue
        latestFailedCommandID = diagnostics.latestFailedCommandID?.uuidString
        latestFailedCommand = diagnostics.latestFailedCommand
        latestFailedWorkingDirectory = diagnostics.latestFailedWorkingDirectory
        latestFailedExitCode = diagnostics.latestFailedExitCode.map(Int.init)
        latestFailedDurationMilliseconds = diagnostics.latestFailedDurationMilliseconds
        latestFailedCommandLifecycleState = diagnostics.latestFailedCommandLifecycleState?.contextLabel
        latestFailedCommandRiskLevel = diagnostics.latestFailedCommandRiskLevel?.contextLabel
        latestFailedCommandRiskReasons = diagnostics.latestFailedCommandRiskReasons.map(\.contextLabel)
        latestFailedCommandStartSource = diagnostics.latestFailedCommandStartSource?.contextLabel
        latestFailedCompletionSource = diagnostics.latestFailedCompletionSource?.contextLabel
        latestFailedCommandBoundaryConfidence = diagnostics.latestFailedCommandBoundaryConfidence?.contextLabel
        latestFailedCommandBoundaryReasons = diagnostics.latestFailedCommandBoundaryReasons.map(\.contextLabel)
        recentFailureCommandID = diagnostics.recentFailureCommandID?.uuidString
        recentFailureWorkingDirectory = diagnostics.recentFailureWorkingDirectory
        recentFailureDiagnostic = diagnostics.recentFailureDiagnostic
        recentFailureFingerprint = diagnostics.recentFailureFingerprint
        recentFailureOutputTailLineNumber = diagnostics.recentFailureOutputTailLineNumber
        recentFailureOutputTailLineText = diagnostics.recentFailureOutputTailLineText
        if let repeatedFailureDiagnostic = diagnostics.repeatedFailureDiagnostic {
            self.repeatedFailureDiagnostic = TerminalToolRepeatedFailureSnapshot(
                diagnostic: repeatedFailureDiagnostic.diagnostic,
                fingerprint: repeatedFailureDiagnostic.fingerprint,
                matchKind: repeatedFailureDiagnostic.matchKind.rawValue,
                commandIDs: repeatedFailureDiagnostic.commandIDs.map(\.uuidString),
                uniqueCommands: repeatedFailureDiagnostic.uniqueCommands,
                uniqueWorkingDirectories: repeatedFailureDiagnostic.uniqueWorkingDirectories,
                contextChanged: repeatedFailureDiagnostic.contextChanged,
                contextStability: repeatedFailureDiagnostic.contextStability.rawValue,
                contextChangeReasons: repeatedFailureDiagnostic.contextChangeReasons.map(\.rawValue),
                firstCommandID: repeatedFailureDiagnostic.firstCommandID.uuidString,
                latestCommandID: repeatedFailureDiagnostic.latestCommandID.uuidString,
                firstCommand: repeatedFailureDiagnostic.firstCommand,
                latestCommand: repeatedFailureDiagnostic.latestCommand,
                firstWorkingDirectory: repeatedFailureDiagnostic.firstWorkingDirectory,
                latestWorkingDirectory: repeatedFailureDiagnostic.latestWorkingDirectory,
                firstOutputTailLineNumber: repeatedFailureDiagnostic.firstOutputTailLineNumber,
                firstOutputTailLineText: repeatedFailureDiagnostic.firstOutputTailLineText,
                latestOutputTailLineNumber: repeatedFailureDiagnostic.latestOutputTailLineNumber,
                latestOutputTailLineText: repeatedFailureDiagnostic.latestOutputTailLineText,
                firstOccurredAt: repeatedFailureDiagnostic.firstOccurredAt,
                latestOccurredAt: repeatedFailureDiagnostic.latestOccurredAt,
                durationMilliseconds: repeatedFailureDiagnostic.durationMilliseconds,
                averageIntervalMilliseconds: repeatedFailureDiagnostic.averageIntervalMilliseconds,
                latestIntervalMilliseconds: repeatedFailureDiagnostic.latestIntervalMilliseconds,
                latestIntervalTrend: repeatedFailureDiagnostic.latestIntervalTrend.rawValue,
                cadence: repeatedFailureDiagnostic.cadence.rawValue,
                retryPauseRecommended: repeatedFailureDiagnostic.retryPauseRecommended,
                retryPauseSeverity: repeatedFailureDiagnostic.retryPauseSeverity.rawValue,
                retryPauseDecision: repeatedFailureDiagnostic.retryPauseDecision.rawValue,
                retryPauseDecisionConfidence: repeatedFailureDiagnostic.retryPauseDecisionConfidence.rawValue,
                retryPauseDecisionAnchorCommandID: repeatedFailureDiagnostic.retryPauseDecisionAnchorCommandID?.uuidString,
                retryPauseDecisionReasons: repeatedFailureDiagnostic.retryPauseDecisionReasons.map(\.rawValue),
                retryPauseDecisionRefreshTriggers: repeatedFailureDiagnostic.retryPauseDecisionRefreshTriggers.map(\.rawValue),
                retryPauseCooldownMilliseconds: repeatedFailureDiagnostic.retryPauseCooldownMilliseconds,
                retryPauseUntil: repeatedFailureDiagnostic.retryPauseUntil,
                retryPauseReasons: repeatedFailureDiagnostic.retryPauseReasons.map(\.rawValue),
                count: repeatedFailureDiagnostic.count
            )
        } else {
            self.repeatedFailureDiagnostic = nil
        }
        suggestedNextInspection = diagnostics.suggestedNextInspection
        suggestedNextCommand = diagnostics.suggestedNextCommand
        if let suggestedNextAction = diagnostics.suggestedNextAction {
            self.suggestedNextAction = TerminalToolDiagnosticActionSnapshot(action: suggestedNextAction)
        } else {
            self.suggestedNextAction = nil
        }
    }
}

struct TerminalToolDiagnosticActionSnapshot: Codable, Equatable {
    let id: String
    let sourceCategory: String
    let confidence: String
    let priorityScore: Int
    let priorityFactors: [String]
    let evidenceAnchors: [String]
    let actionScope: String
    let expectedResultKind: String
    let expectedResultFields: [String]
    let expectedResultSignals: [String]
    let resultParsingHints: [String]
    let resultInterpretationHints: [String]
    let resultDecisionHints: [String]
    let resultCaveats: [String]
    let sensitiveResultFields: [String]
    let resultRedactionHints: [String]
    let resultRefreshTriggers: [String]
    let resultPrivacyLevel: String
    let resultSharingPolicy: String
    let resultRetentionPolicy: String
    let title: String
    let rationale: String
    let command: String
    let expectedSignals: [String]
    let preflightChecks: [String]
    let automationGuardrails: [String]
    let userDecisionPoints: [String]
    let completionCriteria: [String]
    let fallbackNextSteps: [String]
    let safety: String
    let executionMode: String
    let executionTarget: String
    let resultValidityScope: String
    let resultFreshnessPolicy: String
    let resultReuseKeyFields: [String]
    let resultReusePolicy: String
    let resultReuseValidationChecks: [String]
    let retryCondition: String
    let confirmationReasons: [String]
    let requiresConfirmation: Bool

    init(action: CommandDiagnosticAction) {
        id = action.id.rawValue
        sourceCategory = action.sourceCategory.rawValue
        confidence = action.confidence.rawValue
        priorityScore = action.priorityScore
        priorityFactors = action.priorityFactors.map(\.rawValue)
        evidenceAnchors = action.evidenceAnchors.map(\.rawValue)
        actionScope = action.actionScope.rawValue
        expectedResultKind = action.expectedResultKind.rawValue
        expectedResultFields = action.expectedResultFields.map(\.rawValue)
        expectedResultSignals = action.expectedResultSignals.map(\.rawValue)
        resultParsingHints = action.resultParsingHints.map(\.rawValue)
        resultInterpretationHints = action.resultInterpretationHints.map(\.rawValue)
        resultDecisionHints = action.resultDecisionHints.map(\.rawValue)
        resultCaveats = action.resultCaveats.map(\.rawValue)
        sensitiveResultFields = action.sensitiveResultFields.map(\.rawValue)
        resultRedactionHints = action.resultRedactionHints.map(\.rawValue)
        resultRefreshTriggers = action.resultRefreshTriggers.map(\.rawValue)
        resultPrivacyLevel = action.resultPrivacyLevel.rawValue
        resultSharingPolicy = action.resultSharingPolicy.rawValue
        resultRetentionPolicy = action.resultRetentionPolicy.rawValue
        title = action.title
        rationale = action.rationale
        command = action.command
        expectedSignals = action.expectedSignals
        preflightChecks = action.preflightChecks
        automationGuardrails = action.automationGuardrails
        userDecisionPoints = action.userDecisionPoints
        completionCriteria = action.completionCriteria
        fallbackNextSteps = action.fallbackNextSteps
        safety = action.safety.rawValue
        executionMode = action.executionMode.rawValue
        executionTarget = action.executionTarget.rawValue
        resultValidityScope = action.resultValidityScope.rawValue
        resultFreshnessPolicy = action.resultFreshnessPolicy.rawValue
        resultReuseKeyFields = action.resultReuseKeyFields.map(\.rawValue)
        resultReusePolicy = action.resultReusePolicy.rawValue
        resultReuseValidationChecks = action.resultReuseValidationChecks.map(\.rawValue)
        retryCondition = action.retryCondition.rawValue
        confirmationReasons = action.confirmationReasons.map(\.rawValue)
        requiresConfirmation = action.requiresConfirmation
    }
}

struct TerminalToolRepeatedFailureSnapshot: Codable, Equatable {
    let diagnostic: String
    let fingerprint: String
    let matchKind: String
    let commandIDs: [String]
    let uniqueCommands: [String]
    let uniqueWorkingDirectories: [String]
    let contextChanged: Bool
    let contextStability: String
    let contextChangeReasons: [String]
    let firstCommandID: String
    let latestCommandID: String
    let firstCommand: String
    let latestCommand: String
    let firstWorkingDirectory: String?
    let latestWorkingDirectory: String?
    let firstOutputTailLineNumber: Int?
    let firstOutputTailLineText: String?
    let latestOutputTailLineNumber: Int?
    let latestOutputTailLineText: String?
    let firstOccurredAt: Date
    let latestOccurredAt: Date
    let durationMilliseconds: Int
    let averageIntervalMilliseconds: Int
    let latestIntervalMilliseconds: Int
    let latestIntervalTrend: String
    let cadence: String
    let retryPauseRecommended: Bool
    let retryPauseSeverity: String
    let retryPauseDecision: String
    let retryPauseDecisionConfidence: String
    let retryPauseDecisionAnchorCommandID: String?
    let retryPauseDecisionReasons: [String]
    let retryPauseDecisionRefreshTriggers: [String]
    let retryPauseCooldownMilliseconds: Int
    let retryPauseUntil: Date?
    let retryPauseReasons: [String]
    let count: Int
}

struct TerminalToolCommandBlockSnapshot: Codable, Equatable {
    let id: String
    let command: String
    let workingDirectory: String?
    let startedAt: Date
    let endedAt: Date?
    let exitCode: Int32?
    let commandLifecycleState: String
    let commandRiskLevel: String
    let commandRiskReasons: [String]
    let commandStartSource: String?
    let completionSource: String?
    let commandBoundaryConfidence: String
    let commandBoundaryReasons: [String]
    let durationMilliseconds: Int?
    let outputTail: String
    let outputCharacterCount: Int
    let outputSummary: TerminalOutputSummary?
    let isInteractive: Bool
}

struct TerminalToolRequest: Codable {
    var previewRequest: TerminalPreviewRequest? = nil
    var projectRequest: TerminalProjectToolRequest? = nil
    var nativeAgentToken: String? = nil
    var noResponse: Bool? = nil
    var waitSpec: TerminalWaitSpec? = nil
    var waitID: String? = nil
    var attentionID: UUID? = nil
    var attentionVersion: Int? = nil
    var agentKind: TerminalAgentKind? = nil
    var agentReport: TerminalAgentReport? = nil
    var eventCursor: TerminalEventCursor? = nil
    var eventLimit: Int? = nil
    var controlID: String? = nil
    let id: String
    let action: String
    let tab: String?
    let text: String?
    let key: String?
    let bytes: [UInt8]?
    let directory: String?
    let profile: String?
    let shortcut: String?
    let steps: [TerminalShortcutStep]?
    let replace: String?
    let requiresUserAuthentication: Bool?
    let allowsAutomationPlayback: Bool?
    let tunnelName: String?
    let targetHost: String?
    let targetPort: Int?
    let localPort: Int?
    let column: Int?
    let row: Int?
    let button: String?
    let clientID: String?
    let authToken: String?
}

struct TerminalToolShortcutSummary: Codable {
    let id: String
    let title: String
    let eventCount: Int
    let durationMilliseconds: Int
    let hasProtectedInput: Bool
    let requiresUserAuthentication: Bool
    let allowsAutomationPlayback: Bool
    let canPlay: Bool
    let createdAt: Date
    let updatedAt: Date

    init(shortcut: TerminalShortcut, canPlay: Bool) {
        self.id = shortcut.id.uuidString
        self.title = shortcut.title
        self.eventCount = shortcut.eventCount
        self.durationMilliseconds = shortcut.durationMilliseconds
        self.hasProtectedInput = shortcut.hasProtectedInput
        self.requiresUserAuthentication = shortcut.requiresUserAuthentication
        self.allowsAutomationPlayback = shortcut.allowsAutomationPlayback
        self.canPlay = canPlay
        self.createdAt = shortcut.createdAt
        self.updatedAt = shortcut.updatedAt
    }
}

struct TerminalToolResponse: Codable {
    var projectResult: TerminalProjectToolResult? = nil
    var waitResult: TerminalWaitResult? = nil
    var attentionItems: [TerminalAttentionItem]? = nil
    var agentGrant: TerminalAgentGrant? = nil
    var agentReportRoot: String? = nil
    var agent: TerminalAgentSnapshot? = nil
    var eventBatch: TerminalEventBatch? = nil
    let schemaVersion: Int
    let app: String
    let version: String
    let id: String
    let ok: Bool
    let snapshotSequence: Int
    let action: String?
    let tabID: String?
    let shortcuts: [TerminalToolShortcutSummary]?
    let sessionTunnel: TerminalToolSessionTunnelSnapshot?
    let sessionTunnels: [TerminalToolSessionTunnelSnapshot]?
    let message: String?
    let error: String?

    init(
        schemaVersion: Int = 1,
        app: String = "MuseTerm",
        version: String = AppVersion.value,
        id: String,
        ok: Bool,
        snapshotSequence: Int,
        action: String? = nil,
        tabID: String? = nil,
        shortcuts: [TerminalToolShortcutSummary]? = nil,
        sessionTunnel: TerminalToolSessionTunnelSnapshot? = nil,
        sessionTunnels: [TerminalToolSessionTunnelSnapshot]? = nil,
        message: String?,
        error: String?
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.version = version
        self.id = id
        self.ok = ok
        self.snapshotSequence = snapshotSequence
        self.action = action
        self.tabID = tabID
        self.shortcuts = shortcuts
        self.sessionTunnel = sessionTunnel
        self.sessionTunnels = sessionTunnels
        self.message = message
        self.error = error
    }
}

enum TerminalToolMouseButton: String {
    case left, middle, right

    var swiftTermButton: Int {
        switch self {
        case .left: 0
        case .middle: 1
        case .right: 2
        }
    }
}

enum TerminalToolInput {
    static func bytes(text: String?, key: String?, rawBytes: [UInt8]?) -> [UInt8]? {
        if let rawBytes, !rawBytes.isEmpty {
            return rawBytes
        }

        if let key, !key.isEmpty {
            return bytes(forKey: key)
        }

        guard let text else { return nil }
        return Array(text.utf8)
    }

    static func bytes(forKey key: String) -> [UInt8]? {
        let normalized = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "enter", "return":
            return [0x0D]
        case "linefeed", "newline", "lf":
            return [0x0A]
        case "tab":
            return [0x09]
        case "escape", "esc":
            return [0x1B]
        case "backspace", "delete":
            return [0x7F]
        case "ctrl-c", "control-c", "ctl-c", "c-c":
            return [0x03]
        case "ctrl-d", "control-d", "ctl-d", "c-d":
            return [0x04]
        case "ctrl-z", "control-z", "ctl-z", "c-z":
            return [0x1A]
        case "ctrl-l", "control-l", "ctl-l", "c-l":
            return [0x0C]
        case "up":
            return Array("\u{1B}[A".utf8)
        case "down":
            return Array("\u{1B}[B".utf8)
        case "right":
            return Array("\u{1B}[C".utf8)
        case "left":
            return Array("\u{1B}[D".utf8)
        default:
            return nil
        }
    }
}

@MainActor
final class TerminalToolBridge {
    static let shared = TerminalToolBridge()
    private let location: TerminalToolLocation

    private static let requestPollingInterval: TimeInterval = 0.35
    private static let minimumStateWriteInterval: TimeInterval = 2

    private weak var workspace: TerminalWorkspace?
    private var timer: Timer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxHistoryCharacters = 240_000
    private var snapshotSequence = 0
    private var lastResponsePrune = Date.distantPast
    private var lastRuntimeWrite = Date.distantPast
    // 状态发布同时做脏检查与合并：内容没变时跳过；持续输出时最多每 2 秒生成一次
    // “快照 + JSON + 写盘”。请求仍可强制立即刷新，文件 IO 继续放在后台队列。
    private var stateWriteThrottle = TerminalToolStateWriteThrottle(
        minimumInterval: minimumStateWriteInterval
    )
    private let stateWriteQueue = DispatchQueue(
        label: "im.some.museterm.toolbridge.state-write",
        qos: .utility
    )

    init(rootDirectory: URL? = nil) {
        location = TerminalToolLocation(root: rootDirectory ?? TerminalToolPaths.rootDirectory)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func attach(workspace: TerminalWorkspace) {
        self.workspace = workspace
        start()
    }

    func start() {
        do {
            try location.prepare()
            writeStateIfNeeded(force: true)
        } catch {
            NSLog("MuseTerm tool bridge failed to prepare directories: \(error.localizedDescription)")
        }

        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.requestPollingInterval,
            repeats: true
        ) { [weak self] _ in
            guard let bridge = self else { return }
            Task { @MainActor in
                bridge.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let registry = workspace?.sessionRegistry, Date().timeIntervalSince(lastRuntimeWrite) >= 1 {
            lastRuntimeWrite = Date()
            let metadata = TerminalToolRuntime(appEpoch: registry.events.appEpoch,
                pid: ProcessInfo.processInfo.processIdentifier, version: AppVersion.value, cursor: registry.events.cursor,
                backend: backendEventSource(registry))
            do {
                let data = try encoder.encode(metadata)
                let url = location.runtimeFile
                stateWriteQueue.async {
                    do { try TerminalToolPrivateWriter.write(data, to: url) }
                    catch { NSLog("MuseTerm could not write runtime metadata") }
                }
            } catch { NSLog("MuseTerm could not encode runtime metadata") }
        }
        if Date().timeIntervalSince(lastResponsePrune) >= 30 {
            lastResponsePrune = Date()
            do { try TerminalToolResponseRetention.prune(directory: location.responseDirectory) }
            catch { NSLog("MuseTerm could not prune expired tool responses") }
        }
        if let registry = workspace?.sessionRegistry {
            registry.setAgentMonitoringEnabled(workspace?.preferences?.agentMonitoringEnabled ?? true)
            registry.refreshAgents()
            if registry.agentMonitoringEnabled {
                for session in registry.sessions.values { session.sampleAgentIfControllerExists() }
            }
            registry.waits.expire()
        }
        let handledRequestCount = processRequests()
        flushWaitResponses()
        writeStateIfNeeded(force: handledRequestCount > 0)
    }

    private func backendEventSource(_ registry: TerminalSessionRegistry) -> TerminalToolBackendRuntime? {
        let sources = registry.sessions.values.filter { $0.runtimeInfo != nil }
            .compactMap { $0.controller.runtimeHandle?.backendEventSource }
        guard let first = sources.first,
              sources.allSatisfy({ $0.root == first.root && $0.cursor.appEpoch == first.cursor.appEpoch }) else { return nil }
        return first
    }

    private func writeStateIfNeeded(force: Bool) {
        guard let workspace else { return }
        let signature = stateSignature(workspace: workspace)
        guard stateWriteThrottle.shouldWrite(
            signature: signature,
            force: force,
            now: Date()
        ) else { return }
        writeState()
    }

    // 轻量内容签名：只 hash 元数据与 contentRevision，不触碰历史 buffer。
    // 标题/目录/命令块变化都伴随终端输出，已被 contentRevision 覆盖，
    // 单独并入是为了保险与可读性。
    private func stateSignature(workspace: TerminalWorkspace) -> Int {
        var hasher = Hasher()
        hasher.combine(workspace.selectedTab?.id)
        hasher.combine(workspace.projectLayoutRevision)
        hasher.combine(workspace.sessionTunnelPresets)
        hasher.combine(workspace.sessionRegistry.events.sequence)
        for session in workspace.sessionRegistry.sessions.values.sorted(by: { $0.sequence < $1.sequence }) {
            hasher.combine(session.agentStatus?.updatedAt)
        }
        for tab in workspace.tabs {
            hasher.combine(tab.id)
            tab.expireAIControlIfNeeded()
            hasher.combine(tab.aiLease?.expiresAt)
            hasher.combine(tab.aiRequiresTakeover)
            hasher.combine(tab.runtimeInfo?.generation)
            hasher.combine(tab.controller.runtimeHandle?.connected)
            hasher.combine(tab.controller.runtimeHandle?.lastError?.diagnosticCode)
            hasher.combine(tab.controller.runtimeHandle?.lastErrorStage)
            hasher.combine(tab.controller.contentRevision)
            hasher.combine(tab.tabTitle)
            hasher.combine(tab.toolStateText)
            hasher.combine(tab.commandBlocks.count)
        }
        return hasher.finalize()
    }

    private func writeState() {
        guard let workspace else { return }
        snapshotSequence += 1
        var state = TerminalToolState(
            app: "MuseTerm",
            version: AppVersion.value,
            snapshotSequence: snapshotSequence,
            updatedAt: Date(),
            selectedTabID: workspace.selectedTab?.id.uuidString,
            sessionTunnelPresets: workspace.sessionTunnelPresets,
            tabs: workspace.toolSnapshots(maxHistoryCharacters: maxHistoryCharacters)
        )
        state.eventCursor = workspace.sessionRegistry.events.cursor
        state.sessions = workspace.sessionRegistry.snapshots
        state.attentionItems = workspace.sessionRegistry.attention.activeItems
        state.projectLayout = workspace.projectLayout
        state.capabilities = ["agent-state-v1", "session-events-v1", "attention-v1", "wait-v1"]
        let data: Data
        do {
            // JSON 编码依赖默认 MainActor 隔离下生成的 Codable conformance；先在主线程完成，
            // 后台队列只负责文件 IO。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(state)
        } catch {
            NSLog("MuseTerm tool bridge failed to encode state: \(error.localizedDescription)")
            return
        }
        let destination = location.stateFile
        stateWriteQueue.async {
            do {
                try TerminalToolPrivateWriter.write(data, to: destination)
            } catch {
                NSLog("MuseTerm tool bridge failed to write state: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func processRequests() -> Int {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: location.requestDirectory,
                includingPropertiesForKeys: nil
            )
        else { return 0 }

        var handledCount = 0
        for file in files where file.pathExtension == "json" {
            var response: TerminalToolResponse?
            var suppressResponse = false
            do {
                let data = try Data(contentsOf: file)
                let request = try decoder.decode(TerminalToolRequest.self, from: data)
                suppressResponse = request.noResponse == true && ["cancel_wait", "cancel_all_waits"].contains(request.action)
                if handleRuntimeAgentRequest(request) || handleRuntimeControlRequest(request) || handleRuntimeInputRequest(request) {
                    response = nil
                } else if let waiting = try handleWaitRequest(request) {
                    response = waiting
                } else if request.action != "wait_session" {
                    response = perform(request: request)
                }
            } catch {
                response = TerminalToolResponse(
                    id: file.deletingPathExtension().lastPathComponent,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    message: nil,
                    error: (error as? TerminalWaitError)?.rawValue ?? error.localizedDescription
                )
            }

            if let response, !suppressResponse { write(response: response) }
            try? manager.removeItem(at: file)
            handledCount += 1
        }
        return handledCount
    }

    /// Runtime operations finish asynchronously. Publishing an OK response when
    /// an operation is merely queued would misrepresent ownership to CLI/MCP.
    private func handleRuntimeAgentRequest(_ request: TerminalToolRequest) -> Bool {
        let actions: [String: TerminalRuntimeAction] = ["bind_agent": .bindAgent,
            "report_agent_state": .reportAgent, "get_agent_state": .getAgentState]
        guard actions[request.action] != nil || request.action == "bind_native_agent",
              let workspace, let selector = request.tab, let id = UUID(uuidString: selector),
              let tab = workspace.sessionRegistry.sessions[id], let handle = tab.controller.runtimeHandle else { return false }
        let respond: (Result<TerminalRuntimeResponse, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            var response = TerminalToolResponse(id: request.id, ok: true, snapshotSequence: self.snapshotSequence,
                action: request.action, tabID: tab.id.uuidString, message: nil, error: nil)
            switch result {
            case .success(let backend):
                if let info = backend.session {
                    workspace.sessionRegistry.attention.markAgentAuthorityExternal(tabID: id)
                    tab.applyRuntimeInfo(info)
                    workspace.sessionRegistry.attention.adoptAgentItems(backend.attention ?? [], tabID: id, cursor: backend.eventHead)
                    response.agent = info.agent
                }
                response.agentGrant = backend.agentGrant
                if backend.agentGrant != nil { response.agentReportRoot = handle.agentReportRoot.path }
            case .failure(let error):
                let code = (error as? TerminalAgentReportError)?.rawValue
                    ?? (error as? TerminalRuntimeConnectionError)?.diagnosticCode ?? "unavailable"
                response = TerminalToolResponse(id: request.id, ok: false, snapshotSequence: self.snapshotSequence,
                    action: request.action, tabID: tab.id.uuidString, message: nil, error: code)
            }
            self.write(response: response)
        }
        guard request.action != "bind_native_agent" else {
            // Native bootstrap tokens belong to the service's status-only
            // endpoint. They cannot mint grants through this UI endpoint.
            respond(.failure(TerminalAgentReportError.invalidCapability)); return true
        }
        if request.action != "get_agent_state", !workspace.sessionRegistry.agentMonitoringEnabled {
            respond(.failure(TerminalAgentReportError.unavailable)); return true
        }
        if request.action == "bind_agent" {
            let allowed = TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
            TerminalToolAccess.recordAuthorization(clientID: request.clientID, action: request.action, allowed: allowed)
            guard allowed else { respond(.failure(TerminalAgentReportError.invalidCapability)); return true }
            guard request.agentKind != nil else { respond(.failure(TerminalAgentReportError.invalidState)); return true }
        }
        guard let action = actions[request.action] else { return true }
        handle.agentOperation(action, kind: request.agentKind, report: request.agentReport,
            commandID: request.agentKind.flatMap { tab.observedAgentCommandID(kind: $0) }, completion: respond)
        return true
    }

    private func handleRuntimeControlRequest(_ request: TerminalToolRequest) -> Bool {
        let actions: [String: TerminalRuntimeAction] = ["takeover_tab": .acquireControl,
            "renew_tab_control": .renewControl, "release_tab": .releaseControl]
        guard let action = actions[request.action], let workspace,
              let selector = request.tab, let id = UUID(uuidString: selector),
              let tab = try? workspace.toolTab(matching: id.uuidString),
              tab.controller.runtimeHandle != nil else { return false }
        let allowed = workspace.preferences?.toolBridgeWritesEnabled == true
            && TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
        TerminalToolAccess.recordAuthorization(clientID: request.clientID, action: request.action, allowed: allowed)
        let respond: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            let error: String?
            if case .failure(let failure) = result { error = failure.localizedDescription } else { error = nil }
            self.write(response: TerminalToolResponse(id: request.id, ok: error == nil,
                snapshotSequence: self.snapshotSequence, action: request.action, tabID: tab.id.uuidString,
                message: error == nil ? L10n.string("ai_control.updated") : nil, error: error))
        }
        do {
            guard allowed else { throw TerminalToolError.accessDenied }
            guard let owner = request.controlID, !owner.isEmpty, owner.count <= 80 else { throw TerminalAIControlError.retake }
            if action == .releaseControl, tab.aiLease != nil { try tab.authorizeAIInput(owner: owner) }
            tab.changeAIControl(action: action, owner: owner, completion: respond)
        } catch { respond(.failure(error)) }
        return true
    }

    private func handleRuntimeInputRequest(_ request: TerminalToolRequest) -> Bool {
        guard ["input", "send_text", "send_key", "send_mouse"].contains(request.action), let workspace,
              let tab = try? workspace.toolTab(matching: request.tab), tab.controller.runtimeHandle != nil else { return false }
        let allowed = workspace.preferences?.toolBridgeWritesEnabled == true
            && TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
        TerminalToolAccess.recordAuthorization(clientID: request.clientID, action: request.action, allowed: allowed)
        let respond: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            let error: String?
            if case .failure(let failure) = result { error = failure.localizedDescription } else { error = nil }
            self.write(response: TerminalToolResponse(id: request.id, ok: error == nil,
                snapshotSequence: self.snapshotSequence, action: request.action, tabID: tab.id.uuidString,
                message: error == nil ? L10n.format("tools.response.input_sent", tab.tabTitle) : nil, error: error))
        }
        guard allowed else { respond(.failure(TerminalToolError.accessDenied)); return true }
        if request.action == "send_mouse" {
            do {
                try tab.authorizeAIControlInput(owner: request.controlID)
                let bytes = try mouseClickInputBytes(from: request, controller: tab.controller)
                tab.controller.sendToolMouseInput(bytes: bytes, owner: request.controlID, completion: respond)
            } catch { respond(.failure(error)) }
            return true
        }
        guard let bytes = TerminalToolInput.bytes(text: request.text, key: request.key, rawBytes: request.bytes) else {
            respond(.failure(TerminalAIControlError.inputRejected)); return true
        }
        tab.controller.sendToolInput(bytes: bytes, owner: request.controlID, completion: respond)
        return true
    }

    private func mouseClickInputBytes(
        from request: TerminalToolRequest,
        controller: TerminalHostController
    ) throws -> [UInt8] {
        guard let column = request.column, let row = request.row else {
            throw TerminalToolError.mousePositionOutOfBounds
        }
        guard let button = TerminalToolMouseButton(rawValue: request.button ?? "left") else {
            throw TerminalToolError.invalidMouseButton
        }
        return try controller.mouseClickInputBytes(
            button: button,
            column: column,
            row: row
        )
    }

    private func handleWaitRequest(_ request: TerminalToolRequest) throws -> TerminalToolResponse? {
        guard let registry = workspace?.sessionRegistry else {
            if request.action == "wait_session" { throw TerminalWaitError.invalidSpec }
            return nil
        }
        if request.action == "wait_session" {
            guard let spec = request.waitSpec, let owner = request.controlID else { throw TerminalWaitError.invalidSpec }
            try registry.waits.begin(id: request.id, owner: owner, spec: spec)
        } else if request.action == "cancel_wait" || request.action == "cancel_all_waits" {
            guard let owner = request.controlID else { throw TerminalWaitError.invalidSpec }
            if request.action == "cancel_all_waits" { registry.waits.cancelAll(owner: owner) }
            else if let id = request.waitID { _ = registry.waits.cancel(id: id, owner: owner) }
            else { throw TerminalWaitError.invalidSpec }
            return TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                action: request.action, message: nil, error: nil)
        }
        return nil
    }

    private func flushWaitResponses() {
        guard let registry = workspace?.sessionRegistry else { return }
        for result in registry.waits.drainCompletions() {
            var response = TerminalToolResponse(id: result.waitID, ok: true, snapshotSequence: snapshotSequence,
                action: "wait_session", message: nil, error: nil)
            response.waitResult = result
            write(response: response)
        }
    }

    private func perform(request: TerminalToolRequest) -> TerminalToolResponse? {
        guard let workspace else {
            return TerminalToolResponse(
                id: request.id,
                ok: false,
                snapshotSequence: snapshotSequence,
                action: request.action,
                message: nil,
                error: L10n.string("tools.error.no_workspace")
            )
        }

        if TerminalAgentToolService.actions.contains(request.action) {
            return TerminalAgentToolService.perform(request, registry: workspace.sessionRegistry,
                snapshotSequence: snapshotSequence,
                paired: {
                    let allowed = TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
                    TerminalToolAccess.recordAuthorization(clientID: request.clientID,
                        action: request.action, allowed: allowed)
                    return allowed
                })
        }

        if request.action == TerminalProjectToolService.action {
            return TerminalProjectToolService.perform(request, workspace: workspace, snapshotSequence: snapshotSequence) {
                let allowed = workspace.preferences?.toolBridgeWritesEnabled == true
                    && TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
                TerminalToolAccess.recordAuthorization(clientID: request.clientID,
                    action: "project_layout.\(request.projectRequest?.operation.rawValue ?? "invalid")", allowed: allowed)
                return allowed
            }
        }

        if TerminalAttentionToolService.actions.contains(request.action) {
            return TerminalAttentionToolService.perform(request, registry: workspace.sessionRegistry,
                snapshotSequence: snapshotSequence,
                paired: {
                    let allowed = TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
                    TerminalToolAccess.recordAuthorization(clientID: request.clientID, action: request.action, allowed: allowed)
                    return allowed
                })
        }

        if Self.writeActions.contains(request.action) {
            let allowed = workspace.preferences?.toolBridgeWritesEnabled == true
                && TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
            TerminalToolAccess.recordAuthorization(
                clientID: request.clientID,
                action: request.action,
                allowed: allowed
            )
            guard allowed else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("tools.error.access_denied")
                )
            }
        }

        switch request.action {
        case "preview":
            return TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: snapshotSequence)
        case "takeover_tab", "renew_tab_control", "release_tab":
            do {
                guard let owner = request.controlID, !owner.isEmpty, owner.count <= 80,
                      let selector = request.tab, let tabID = UUID(uuidString: selector) else {
                    throw TerminalAIControlError.retake
                }
                let tab = try workspace.toolTab(matching: tabID.uuidString)
                switch request.action {
                case "takeover_tab": try tab.takeAIControl(owner: owner)
                case "renew_tab_control": try tab.renewAIControl(owner: owner)
                default:
                    tab.expireAIControlIfNeeded()
                    if tab.aiLease != nil {
                        try tab.authorizeAIInput(owner: owner)
                        tab.releaseAIControl(reason: "released")
                    }
                }
                return TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                    action: request.action, tabID: tab.id.uuidString,
                    message: L10n.string("ai_control.updated"), error: nil)
            } catch {
                return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                    action: request.action, message: nil, error: error.localizedDescription)
            }
        case "list_shortcuts":
            let toolWriteAllowed = workspace.preferences?.toolBridgeWritesEnabled == true
                && TerminalToolAccess.authorizes(clientID: request.clientID, token: request.authToken)
            let shortcuts = workspace.shortcuts.map { shortcut in
                TerminalToolShortcutSummary(
                    shortcut: shortcut,
                    canPlay: toolWriteAllowed && MuseTermScriptingPolicy.canPlay(shortcut)
                )
            }
            return TerminalToolResponse(
                id: request.id,
                ok: true,
                snapshotSequence: snapshotSequence,
                action: request.action,
                shortcuts: shortcuts,
                message: L10n.format("tools.response.shortcuts_listed", shortcuts.count),
                error: nil
            )
        case "list_session_tunnels":
            let tunnels = workspace.tabs.compactMap { tab in
                tab.sessionTunnelStatus.map(TerminalToolSessionTunnelSnapshot.init(status:))
            }
            return TerminalToolResponse(
                id: request.id,
                ok: true,
                snapshotSequence: snapshotSequence,
                action: request.action,
                sessionTunnels: tunnels,
                message: L10n.format("tools.response.session_tunnels_listed", tunnels.count),
                error: nil
            )
        case "create_tab":
            workspace.newTab(startDirectory: request.directory)
            guard let tab = workspace.selectedTab else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("tools.error.no_workspace")
                )
            }
            return TerminalToolResponse(
                id: request.id,
                ok: true,
                snapshotSequence: snapshotSequence,
                action: request.action,
                tabID: tab.id.uuidString,
                message: L10n.format("tools.response.tab_created", tab.tabTitle),
                error: nil
            )
        case "open_ssh_profile":
            let name = request.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("applescript.error.empty_input")
                )
            }
            let profiles = MuseTermScriptingRegistry.sshStore?.profiles ?? []
            guard let profile = profiles.first(where: { $0.displayName == name })
                ?? profiles.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame })
            else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.format("applescript.error.profile_not_found", name)
                )
            }
            workspace.openSSH(profile: profile)
            guard let tab = workspace.selectedTab else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("tools.error.no_workspace")
                )
            }
            return TerminalToolResponse(
                id: request.id,
                ok: true,
                snapshotSequence: snapshotSequence,
                action: request.action,
                tabID: tab.id.uuidString,
                message: L10n.format("tools.response.ssh_profile_opened", profile.displayName),
                error: nil
            )
        case "start_session_tunnel":
            let configuration = SessionTunnelConfiguration(
                name: request.tunnelName ?? "",
                targetHost: request.targetHost ?? "",
                targetPort: request.targetPort ?? 0,
                localPort: request.localPort ?? 0
            )
            do {
                let validated = try configuration.validated()
                let tab = try workspace.startToolSessionTunnel(configuration: validated, in: request.tab)
                let tunnel = tab.sessionTunnelStatus
                    .map(TerminalToolSessionTunnelSnapshot.init(status:))
                    ?? TerminalToolSessionTunnelSnapshot(status: .starting(configuration: validated))
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    tabID: tab.id.uuidString,
                    sessionTunnel: tunnel,
                    message: L10n.format("tools.response.session_tunnel_started", tunnel.localEndpoint),
                    error: nil
                )
            } catch {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        case "stop_session_tunnel":
            do {
                let tab = try workspace.stopToolSessionTunnel(in: request.tab)
                let tunnel = tab.sessionTunnelStatus.map(TerminalToolSessionTunnelSnapshot.init(status:))
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    tabID: tab.id.uuidString,
                    sessionTunnel: tunnel,
                    message: L10n.string("tools.response.session_tunnel_stopping"),
                    error: nil
                )
            } catch {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        case "save_shortcut":
            return saveShortcut(request, workspace: workspace)
        case "play_shortcut":
            do {
                let tab = try workspace.toolTab(matching: request.tab)
                try tab.authorizeAIInput(owner: request.controlID)
                if tab.aiLease != nil { throw TerminalAIControlError.busy }
            } catch {
                return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                    action: request.action, message: nil, error: error.localizedDescription)
            }
            let title = request.shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("applescript.error.empty_input")
                )
            }
            let shortcut = workspace.shortcuts.first { $0.title == title }
                ?? workspace.shortcuts.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
            guard let shortcut else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.format("applescript.error.shortcut_not_found", title)
                )
            }
            let requestID = request.id
            let action = request.action
            let selector = request.tab
            let needsAuthentication = shortcut.requiresUserAuthentication
                && MuseTermScriptingPolicy.canPlay(shortcut)
            let reply = TerminalShortcutAutomationReply()
            workspace.playAutomationShortcut(shortcut, in: selector, wait: 45) { [weak self] result in
                guard let self else {
                    reply.finish(.failure(TerminalShortcutPlaybackError.authenticationCancelled))
                    return
                }
                switch result {
                case .success(let tab):
                    reply.finish(.success(TerminalToolResponse(
                        id: requestID,
                        ok: true,
                        snapshotSequence: self.snapshotSequence,
                        action: action,
                        tabID: tab.id.uuidString,
                        message: L10n.format("tools.response.shortcut_played", shortcut.title),
                        error: nil
                    )))
                case .failure(let error):
                    reply.finish(.failure(error))
                }
            }
            if needsAuthentication {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let settled = reply.await(seconds: 45)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch settled {
                        case .success(let response):
                            self.write(response: response)
                        case .failure(let error):
                            self.write(response: TerminalToolResponse(
                                id: requestID,
                                ok: false,
                                snapshotSequence: self.snapshotSequence,
                                action: action,
                                message: nil,
                                error: error.localizedDescription
                            ))
                        }
                    }
                }
                return TerminalToolResponse(
                    id: requestID,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: action,
                    message: L10n.format("tools.response.shortcut_authentication_required", shortcut.title),
                    error: nil
                )
            }
            switch reply.await(seconds: 45) {
            case .success(let response):
                return response
            case .failure(let error):
                return TerminalToolResponse(
                    id: requestID,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: action,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        case "send_mouse":
            do {
                let tab = try workspace.toolTab(matching: request.tab)
                try tab.authorizeAIControlInput(owner: request.controlID)
                let bytes = try mouseClickInputBytes(from: request, controller: tab.controller)
                try tab.controller.sendToolMouseInput(bytes: bytes, owner: request.controlID)
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    tabID: tab.id.uuidString,
                    message: L10n.format("tools.response.input_sent", tab.tabTitle),
                    error: nil
                )
            } catch {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        case "input", "send_text", "send_key":
            guard let bytes = TerminalToolInput.bytes(text: request.text, key: request.key, rawBytes: request.bytes) else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("tools.error.empty_input")
                )
            }

            do {
                let tab = try workspace.sendToolInput(to: request.tab, bytes: bytes, owner: request.controlID)
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    tabID: tab.id.uuidString,
                    message: L10n.format("tools.response.input_sent", tab.tabTitle),
                    error: nil
                )
            } catch {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        default:
            return TerminalToolResponse(
                id: request.id,
                ok: false,
                snapshotSequence: snapshotSequence,
                action: request.action,
                message: nil,
                error: L10n.format("tools.error.unknown_action", request.action)
            )
        }
    }

    private func saveShortcut(_ request: TerminalToolRequest, workspace: TerminalWorkspace) -> TerminalToolResponse {
        func rejected(_ error: Error) -> TerminalToolResponse {
            TerminalToolResponse(
                id: request.id,
                ok: false,
                snapshotSequence: snapshotSequence,
                action: request.action,
                message: nil,
                error: error.localizedDescription
            )
        }

        let title = request.shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetTitle = request.replace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var target: TerminalShortcut?
        if !targetTitle.isEmpty {
            let matches = workspace.shortcuts.filter {
                $0.title == targetTitle || $0.title.localizedCaseInsensitiveCompare(targetTitle) == .orderedSame
            }
            guard let match = matches.first else {
                return rejected(TerminalShortcutDraftError.targetNotFound(targetTitle))
            }
            guard matches.count == 1 else {
                return rejected(TerminalShortcutDraftError.ambiguousTarget(targetTitle))
            }
            target = match
        }

        let otherTitles = workspace.shortcuts
            .filter { $0.id != target?.id }
            .map(\.title)
        let shortcut: TerminalShortcut
        do {
            shortcut = try TerminalShortcutDraft.make(
                title: title,
                steps: request.steps ?? [],
                replacing: target,
                existingTitles: otherTitles,
                requiresUserAuthentication: request.requiresUserAuthentication,
                allowsAutomationPlayback: request.allowsAutomationPlayback
            )
        } catch {
            return rejected(error)
        }

        workspace.upsertShortcut(shortcut)
        let saved = workspace.shortcuts.first { $0.id == shortcut.id } ?? shortcut
        return TerminalToolResponse(
            id: request.id,
            ok: true,
            snapshotSequence: snapshotSequence,
            action: request.action,
            shortcuts: [TerminalToolShortcutSummary(shortcut: saved, canPlay: MuseTermScriptingPolicy.canPlay(saved))],
            message: L10n.format("tools.response.shortcut_saved", saved.title),
            error: nil
        )
    }

    private func write(response: TerminalToolResponse) {
        do {
            let data = try encoder.encode(response)
            let url = location.responseDirectory.appendingPathComponent("\(response.id).json")
            try TerminalToolPrivateWriter.write(data, to: url)
        } catch {
            NSLog("MuseTerm tool bridge failed to write response: \(error.localizedDescription)")
        }
    }

    private static let writeActions: Set<String> = [
        "preview",
        "takeover_tab", "renew_tab_control", "release_tab",
        "create_tab",
        "open_ssh_profile",
        "play_shortcut",
        "save_shortcut",
        "input",
        "send_text",
        "send_key",
        "send_mouse",
        "start_session_tunnel",
        "stop_session_tunnel"
    ]
}

struct TerminalToolStateWriteThrottle {
    let minimumInterval: TimeInterval

    private var lastWrittenSignature: Int?
    private var lastWriteDate: Date?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldWrite(signature: Int, force: Bool, now: Date) -> Bool {
        guard force || signature != lastWrittenSignature else { return false }

        if !force,
           let lastWriteDate,
           now.timeIntervalSince(lastWriteDate) < minimumInterval {
            return false
        }

        lastWrittenSignature = signature
        lastWriteDate = now
        return true
    }
}

enum TerminalToolError: LocalizedError {
    case accessDenied
    case tabNotFound(String)
    case processUnavailable
    case sessionTunnelActive
    case sessionTunnelNotActive
    case invalidMouseButton
    case mousePositionOutOfBounds
    case mouseReportingUnavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied: return L10n.string("tools.error.access_denied")
        case .tabNotFound(let selector):
            return L10n.format("tools.error.tab_not_found", selector)
        case .processUnavailable:
            return L10n.string("tools.error.process_unavailable")
        case .sessionTunnelActive:
            return L10n.string("tools.error.session_tunnel_active")
        case .sessionTunnelNotActive:
            return L10n.string("tools.error.session_tunnel_not_active")
        case .invalidMouseButton:
            return L10n.string("tools.error.invalid_mouse_button")
        case .mousePositionOutOfBounds:
            return L10n.string("tools.error.mouse_position_out_of_bounds")
        case .mouseReportingUnavailable:
            return L10n.string("tools.error.mouse_reporting_unavailable")
        }
    }
}
