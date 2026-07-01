import Foundation

struct TerminalToolPaths {
    static let supportDirectoryName = "MuseTerm/Tools"
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
        try manager.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
    }
}

struct TerminalToolState: Codable {
    let schemaVersion: Int
    let app: String
    let version: String
    let snapshotSequence: Int
    let updatedAt: Date
    let selectedTabID: String?
    let tabs: [TerminalToolTabSnapshot]

    init(
        schemaVersion: Int = 1,
        app: String,
        version: String,
        snapshotSequence: Int = 0,
        updatedAt: Date,
        selectedTabID: String?,
        tabs: [TerminalToolTabSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.version = version
        self.snapshotSequence = snapshotSequence
        self.updatedAt = updatedAt
        self.selectedTabID = selectedTabID
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
    let latestFailedCommandStartSource: String?
    let latestFailedCompletionSource: String?
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
        latestFailedCommandStartSource = diagnostics.latestFailedCommandStartSource?.contextLabel
        latestFailedCompletionSource = diagnostics.latestFailedCompletionSource?.contextLabel
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
    let commandStartSource: String?
    let completionSource: String?
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
            NSLog("MuseTerm tool bridge failed to prepare directories: \(error.localizedDescription)")
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
        processRequests()
        writeState()
    }

    private func writeState() {
        guard let workspace else { return }
        do {
            snapshotSequence += 1
            let state = TerminalToolState(
                app: "MuseTerm",
                version: AppVersion.value,
                snapshotSequence: snapshotSequence,
                updatedAt: Date(),
                selectedTabID: workspace.selectedTab?.id.uuidString,
                tabs: workspace.toolSnapshots(maxHistoryCharacters: maxHistoryCharacters)
            )
            let data = try encoder.encode(state)
            try data.write(to: TerminalToolPaths.stateFile, options: .atomic)
        } catch {
            NSLog("MuseTerm tool bridge failed to write state: \(error.localizedDescription)")
        }
    }

    private func processRequests() {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: TerminalToolPaths.requestDirectory,
                includingPropertiesForKeys: nil
            )
        else { return }

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
        }
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

        switch request.action {
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
        } catch {
            NSLog("MuseTerm tool bridge failed to write response: \(error.localizedDescription)")
        }
    }
}

enum TerminalToolError: LocalizedError {
    case tabNotFound(String)
    case processUnavailable

    var errorDescription: String? {
        switch self {
        case .tabNotFound(let selector):
            return L10n.format("tools.error.tab_not_found", selector)
        case .processUnavailable:
            return L10n.string("tools.error.process_unavailable")
        }
    }
}
