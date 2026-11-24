import Foundation

/// A preference declared by a plugin. Values stay in the host; plugins never store a secret here.
struct TerminalPluginPreference: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case text
        case boolean
        case dropdown
    }

    struct Choice: Equatable, Sendable {
        let title: String
        let value: String
    }

    let name: String
    let kind: Kind
    let title: String
    let choices: [Choice]
}

/// A command declared by a plugin manifest. The palette can show it without running the plugin.
struct TerminalPluginCommand: Equatable, Sendable {
    static let maximumPriority = 380

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let priority: Int
    let exportName: String
}

/// One installed plugin, read from its package.json. `enabled` is the user's switch and defaults to off.
struct TerminalPlugin: Identifiable, Equatable, Sendable {
    let id: String
    let directory: URL
    let displayName: String
    let version: String
    let permissions: [String]
    let commands: [TerminalPluginCommand]
    let preferences: [TerminalPluginPreference]
    let suggestExport: String?
    let recordingExport: String?
    var enabled: Bool
    var source: String

    var entryURL: URL {
        directory.appendingPathComponent(entry)
    }

    /// Relative path declared by the manifest. The host never substitutes another file.
    let entry: String
}

/// The result of running one declared export. `fill` never includes a return; the host confirms it first.
enum TerminalPluginResult: Equatable, Sendable {
    case message(title: String, body: String?)
    case fill(command: String)
    case suggestions([(command: String, explanation: String)])

    static func == (lhs: TerminalPluginResult, rhs: TerminalPluginResult) -> Bool {
        switch (lhs, rhs) {
        case let (.message(leftTitle, leftBody), .message(rightTitle, rightBody)):
            return leftTitle == rightTitle && leftBody == rightBody
        case let (.fill(left), .fill(right)):
            return left == right
        case let (.suggestions(left), .suggestions(right)):
            return left.map { "\($0.command)\n\($0.explanation)" } == right.map { "\($0.command)\n\($0.explanation)" }
        default:
            return false
        }
    }
}

/// What a plugin is told after a recording has been saved. No bytes, no text, no secret lengths.
struct TerminalPluginRecordingEvent: Equatable, Sendable {
    let id: String
    let title: String
    let eventCount: Int
    let durationMilliseconds: Int
    let hasProtectedInput: Bool
    let requiresUserAuthentication: Bool
    let allowsAutomationPlayback: Bool
}

/// Where a command would run. Command exports only receive the first three fields.
struct TerminalPluginTabContext: Equatable, Sendable {
    let id: String
    let targetKind: String
    let environment: String
    let targetName: String
    let user: String?
    let host: String?
    let workingDirectory: String?
    let shell: String?
}

struct TerminalPluginIssue: Equatable {
    let path: String
    let message: String
}

struct TerminalPluginManifestFailure: Error {
    let issues: [TerminalPluginIssue]
}

enum TerminalPluginError: LocalizedError, Equatable {
    case notInstalled(String)
    case disabled(String)
    case missingExport(String)
    case missingPermission(String)
    case timedOut
    case failed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let id): return L10n.format("plugin.error.not_installed", id)
        case .disabled(let name): return L10n.format("plugin.error.disabled", name)
        case .missingExport(let name): return L10n.format("plugin.error.missing_export", name)
        case .missingPermission(let permission): return L10n.format("plugin.error.missing_permission", permission)
        case .timedOut: return L10n.string("plugin.error.timed_out")
        case .failed(let reason): return L10n.format("plugin.error.failed", reason)
        case .invalidResponse(let reason): return L10n.format("plugin.error.invalid_response", reason)
        }
    }
}
