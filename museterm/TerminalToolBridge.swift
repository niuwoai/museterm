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
    let app: String
    let version: String
    let updatedAt: Date
    let selectedTabID: String?
    let tabs: [TerminalToolTabSnapshot]
}

struct TerminalToolTabSnapshot: Codable, Equatable {
    let id: String
    let index: Int
    let title: String
    let subtitle: String?
    let currentDirectory: String?
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
    let failedCommandCount: Int
    let diagnosticSeverity: String
    let diagnosticCategory: String
    let diagnosticCategoryEvidence: String?
    let diagnosticCategoryConfidence: String
    let latestFailedCommand: String?
    let recentFailureDiagnostic: String?
    let recentFailureFingerprint: String?
    let repeatedFailureDiagnostic: TerminalToolRepeatedFailureSnapshot?
    let suggestedNextInspection: String?
    let suggestedNextCommand: String?
    let suggestedNextAction: TerminalToolDiagnosticActionSnapshot?

    init(diagnostics: CommandBlockDiagnostics) {
        failedCommandCount = diagnostics.failedCommandCount
        diagnosticSeverity = diagnostics.diagnosticSeverity.rawValue
        diagnosticCategory = diagnostics.diagnosticCategory.rawValue
        diagnosticCategoryEvidence = diagnostics.diagnosticCategoryEvidence
        diagnosticCategoryConfidence = diagnostics.diagnosticCategoryConfidence.rawValue
        latestFailedCommand = diagnostics.latestFailedCommand
        recentFailureDiagnostic = diagnostics.recentFailureDiagnostic
        recentFailureFingerprint = diagnostics.recentFailureFingerprint
        if let repeatedFailureDiagnostic = diagnostics.repeatedFailureDiagnostic {
            self.repeatedFailureDiagnostic = TerminalToolRepeatedFailureSnapshot(
                diagnostic: repeatedFailureDiagnostic.diagnostic,
                fingerprint: repeatedFailureDiagnostic.fingerprint,
                matchKind: repeatedFailureDiagnostic.matchKind.rawValue,
                firstOccurredAt: repeatedFailureDiagnostic.firstOccurredAt,
                latestOccurredAt: repeatedFailureDiagnostic.latestOccurredAt,
                durationMilliseconds: repeatedFailureDiagnostic.durationMilliseconds,
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
    let title: String
    let rationale: String
    let command: String
    let expectedSignals: [String]
    let fallbackNextSteps: [String]
    let safety: String
    let requiresConfirmation: Bool

    init(action: CommandDiagnosticAction) {
        id = action.id.rawValue
        sourceCategory = action.sourceCategory.rawValue
        confidence = action.confidence.rawValue
        title = action.title
        rationale = action.rationale
        command = action.command
        expectedSignals = action.expectedSignals
        fallbackNextSteps = action.fallbackNextSteps
        safety = action.safety.rawValue
        requiresConfirmation = action.requiresConfirmation
    }
}

struct TerminalToolRepeatedFailureSnapshot: Codable, Equatable {
    let diagnostic: String
    let fingerprint: String
    let matchKind: String
    let firstOccurredAt: Date
    let latestOccurredAt: Date
    let durationMilliseconds: Int
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
    let id: String
    let ok: Bool
    let message: String?
    let error: String?
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
            let state = TerminalToolState(
                app: "MuseTerm",
                version: AppVersion.value,
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
                    message: nil,
                    error: L10n.string("tools.error.empty_input")
                )
            }

            do {
                let tab = try workspace.sendToolInput(to: request.tab, bytes: bytes)
                return TerminalToolResponse(
                    id: request.id,
                    ok: true,
                    message: L10n.format("tools.response.input_sent", tab.tabTitle),
                    error: nil
                )
            } catch {
                return TerminalToolResponse(
                    id: request.id,
                    ok: false,
                    message: nil,
                    error: error.localizedDescription
                )
            }
        default:
            return TerminalToolResponse(
                id: request.id,
                ok: false,
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
