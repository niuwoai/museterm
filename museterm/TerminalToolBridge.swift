import Foundation

struct TerminalToolPaths {
    static let supportDirectoryName = "QTerm/Tools"
    static let stateFileName = "state.json"
    static let requestDirectoryName = "requests"
    static let responseDirectoryName = "responses"

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
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
    let id: String
    let action: String
    let tab: String?
    let text: String?
    let key: String?
    let bytes: [UInt8]?
    let directory: String?
    let profile: String?
    let shortcut: String?
    let tunnelName: String?
    let targetHost: String?
    let targetPort: Int?
    let localPort: Int?
    let clientID: String?
    let authToken: String?
}

struct TerminalToolShortcutSummary: Codable {
    let id: String
    let title: String
    let eventCount: Int
    let durationMilliseconds: Int
    let hasProtectedInput: Bool
    let canPlay: Bool
    let createdAt: Date
    let updatedAt: Date

    init(shortcut: TerminalShortcut, canPlay: Bool) {
        self.id = shortcut.id.uuidString
        self.title = shortcut.title
        self.eventCount = shortcut.eventCount
        self.durationMilliseconds = shortcut.durationMilliseconds
        self.hasProtectedInput = shortcut.hasProtectedInput
        self.canPlay = canPlay
        self.createdAt = shortcut.createdAt
        self.updatedAt = shortcut.updatedAt
    }
}

struct TerminalToolResponse: Codable {
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
        app: String = "QTerm",
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

    private weak var workspace: TerminalWorkspace?
    private var timer: Timer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxHistoryCharacters = 240_000
    private var snapshotSequence = 0
    // 状态文件写盘的脏检查：内容签名没变就跳过整个“快照 + JSON 编码 + 写盘”，
    // 空闲时 tick 只剩一次目录轮询。写盘在串行后台队列执行，不占主线程。
    private var lastWrittenSignature: Int?
    private let stateWriteQueue = DispatchQueue(
        label: "im.some.museterm.toolbridge.state-write",
        qos: .utility
    )

    private init() {
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
            try TerminalToolPaths.ensureDirectories()
            writeState()
        } catch {
            NSLog("QTerm tool bridge failed to prepare directories: \(error.localizedDescription)")
        }

        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let bridge = self else { return }
            Task { @MainActor in
                bridge.tick()
            }
        }
    }

    private func tick() {
        let handledRequestCount = processRequests()
        writeStateIfNeeded(force: handledRequestCount > 0)
    }

    private func writeStateIfNeeded(force: Bool) {
        guard let workspace else { return }
        let signature = stateSignature(workspace: workspace)
        guard force || signature != lastWrittenSignature else { return }
        lastWrittenSignature = signature
        writeState()
    }

    // 轻量内容签名：只 hash 元数据与 contentRevision，不触碰历史 buffer。
    // 标题/目录/命令块变化都伴随终端输出，已被 contentRevision 覆盖，
    // 单独并入是为了保险与可读性。
    private func stateSignature(workspace: TerminalWorkspace) -> Int {
        var hasher = Hasher()
        hasher.combine(workspace.selectedTab?.id)
        hasher.combine(workspace.sessionTunnelPresets)
        for tab in workspace.tabs {
            hasher.combine(tab.id)
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
        let state = TerminalToolState(
            app: "QTerm",
            version: AppVersion.value,
            snapshotSequence: snapshotSequence,
            updatedAt: Date(),
            selectedTabID: workspace.selectedTab?.id.uuidString,
            sessionTunnelPresets: workspace.sessionTunnelPresets,
            tabs: workspace.toolSnapshots(maxHistoryCharacters: maxHistoryCharacters)
        )
        let data: Data
        do {
            // JSON 编码依赖默认 MainActor 隔离下生成的 Codable conformance；先在主线程完成，
            // 后台队列只负责文件 IO。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(state)
        } catch {
            NSLog("QTerm tool bridge failed to encode state: \(error.localizedDescription)")
            return
        }
        stateWriteQueue.async {
            do {
                try data.write(to: TerminalToolPaths.stateFile, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: TerminalToolPaths.stateFile.path
                )
            } catch {
                NSLog("QTerm tool bridge failed to write state: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func processRequests() -> Int {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: TerminalToolPaths.requestDirectory,
                includingPropertiesForKeys: nil
            )
        else { return 0 }

        var handledCount = 0
        for file in files where file.pathExtension == "json" {
            let response: TerminalToolResponse
            do {
                let data = try Data(contentsOf: file)
                let request = try decoder.decode(TerminalToolRequest.self, from: data)
                response = perform(request: request)
            } catch {
                response = TerminalToolResponse(
                    id: file.deletingPathExtension().lastPathComponent,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    message: nil,
                    error: error.localizedDescription
                )
            }

            write(response: response)
            try? manager.removeItem(at: file)
            handledCount += 1
        }
        return handledCount
    }

    private func perform(request: TerminalToolRequest) -> TerminalToolResponse {
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
        case "play_shortcut":
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
            guard MuseTermScriptingPolicy.canPlay(shortcut) else {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    message: nil,
                    error: L10n.string("applescript.error.shortcut_protected")
                )
            }
            do {
                let tab = try workspace.playToolShortcut(shortcut, in: request.tab)
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    snapshotSequence: snapshotSequence,
                    action: request.action,
                    tabID: tab.id.uuidString,
                    message: L10n.format("tools.response.shortcut_played", shortcut.title),
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
                let tab = try workspace.sendToolInput(to: request.tab, bytes: bytes)
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

    private func write(response: TerminalToolResponse) {
        do {
            let data = try encoder.encode(response)
            let url = TerminalToolPaths.responseDirectory.appendingPathComponent("\(response.id).json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("QTerm tool bridge failed to write response: \(error.localizedDescription)")
        }
    }

    private static let writeActions: Set<String> = [
        "create_tab",
        "open_ssh_profile",
        "play_shortcut",
        "input",
        "send_text",
        "send_key",
        "start_session_tunnel",
        "stop_session_tunnel"
    ]
}

enum TerminalToolError: LocalizedError {
    case tabNotFound(String)
    case processUnavailable
    case sessionTunnelActive
    case sessionTunnelNotActive

    var errorDescription: String? {
        switch self {
        case .tabNotFound(let selector):
            return L10n.format("tools.error.tab_not_found", selector)
        case .processUnavailable:
            return L10n.string("tools.error.process_unavailable")
        case .sessionTunnelActive:
            return L10n.string("tools.error.session_tunnel_active")
        case .sessionTunnelNotActive:
            return L10n.string("tools.error.session_tunnel_not_active")
        }
    }
}
