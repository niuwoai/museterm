import CryptoKit
import Foundation

enum LearnedCommandCategory: String, Codable, CaseIterable {
    case development
    case build
    case test
    case git
    case service
    case deploy
    case database
    case network
    case system
    case custom

    var title: String {
        L10n.string("learned_command.category.\(rawValue)")
    }

    var systemImage: String {
        switch self {
        case .development: return "terminal"
        case .build: return "hammer"
        case .test: return "checkmark.seal"
        case .git: return "arrow.triangle.branch"
        case .service: return "server.rack"
        case .deploy: return "shippingbox"
        case .database: return "cylinder"
        case .network: return "network"
        case .system: return "gearshape.2"
        case .custom: return "command"
        }
    }
}

struct LearnedCommandRecord: Codable, Equatable, Identifiable {
    static let discoveryThreshold = 3
    static let minimumSuccessfulExecutions = 2

    var id: String
    var command: String
    var context: TerminalExecutionContext
    var category: LearnedCommandCategory
    var observationCount: Int
    var successCount: Int
    var failureCount: Int
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastFailureAt: Date?
    var lastExecutedAt: Date?
    var isPinned: Bool
    var isDismissed: Bool

    var isDiscoverable: Bool {
        !isDismissed
            && observationCount >= Self.discoveryThreshold
            && successCount >= Self.minimumSuccessfulExecutions
    }

    var successRate: Double {
        guard observationCount > 0 else { return 0 }
        return Double(successCount) / Double(observationCount)
    }

    var displaySubtitle: String {
        let learned = L10n.format("learned_command.learned_count", observationCount)
        return "\(learned) · \(category.title) · \(context.displaySummary)"
    }

    func rankingScore(now: Date = Date()) -> Double {
        let ageDays = max(0, now.timeIntervalSince(lastSeenAt) / 86_400)
        let recency = exp(-ageDays / 30)
        let frequency = min(1, log1p(Double(observationCount)) / log(16))
        let contextConfidence = context.confidence == .observed ? 1.0 : 0.65
        return frequency * 0.35 + recency * 0.25 + successRate * 0.20 + contextConfidence * 0.20
    }
}

enum LearnedCommandEligibility {
    static func accepts(_ block: TerminalCommandBlock) -> Bool {
        let command = normalizedCommand(block.command)
        guard block.endedAt != nil,
              !command.isEmpty,
              !command.contains(where: { $0.isNewline }),
              block.commandBoundaryConfidence != .low,
              !block.isInteractive,
              !RunbookSensitiveRedactor.containsSensitiveData(command),
              !containsSensitiveAssignment(command),
              block.commandRiskProfile.level != .dangerous,
              !isContextOnlyCommand(command),
              !isKnownInteractiveCommand(command) else {
            return false
        }
        return true
    }

    static func normalizedCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isContextOnlyCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let exact = ["cd", "pushd", "popd", "ssh", "sudo -i", "sudo -s", "exit", "logout", "clear"]
        if exact.contains(lower) { return true }
        return ["cd ", "pushd ", "ssh ", "su "].contains { lower.hasPrefix($0) }
    }

    private static func isKnownInteractiveCommand(_ command: String) -> Bool {
        let executable = firstExecutable(in: command)
        return ["bash", "fish", "less", "man", "more", "nano", "ssh", "su", "top", "vim", "vi", "zsh"]
            .contains(executable)
    }

    static func firstExecutable(in command: String) -> String {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        if tokens[0] == "sudo" {
            return tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased() ?? "sudo"
        }
        return URL(fileURLWithPath: tokens[0]).lastPathComponent.lowercased()
    }

    private static func containsSensitiveAssignment(_ command: String) -> Bool {
        let lower = command.lowercased()
        let sensitiveNames = [
            "api_key", "apikey", "api_token", "access_key", "access_token", "auth_token",
            "secret", "token", "password", "passwd", "private_key"
        ]
        return sensitiveNames.contains { name in
            lower.range(of: "(?:^|[^a-z0-9_])\(name)\\s*=", options: .regularExpression) != nil
        }
    }
}

enum LearnedCommandClassifier {
    static func category(for command: String) -> LearnedCommandCategory {
        let executable = LearnedCommandEligibility.firstExecutable(in: command)
        let lower = command.lowercased()

        if executable == "git" { return .git }
        if ["go", "swift", "xcodebuild", "yarn", "npm", "pnpm", "ruby", "cargo"].contains(executable) {
            if lower.contains(" test") || lower.contains("spec") { return .test }
            if lower.contains(" build") || executable == "xcodebuild" { return .build }
            return .development
        }
        if ["systemctl", "launchctl", "service", "docker", "podman", "kubectl"].contains(executable) {
            return .service
        }
        if ["deploy", "helm", "scp", "rsync", "terraform", "ansible-playbook"].contains(executable)
            || lower.contains("deploy") {
            return .deploy
        }
        if ["mysql", "psql", "sqlite3", "mongosh", "redis-cli", "migrate", "goose"].contains(executable) {
            return .database
        }
        if ["curl", "dig", "host", "lsof", "netstat", "ping", "ss", "traceroute"].contains(executable) {
            return .network
        }
        if ["chmod", "chown", "defaults", "df", "du", "kill", "ps", "uname"].contains(executable) {
            return .system
        }
        return .custom
    }
}

final class LearnedCommandIndex {
    private static let rapidFailureWindow: TimeInterval = 60
    private var recordsByID: [String: LearnedCommandRecord]

    init(records: [LearnedCommandRecord] = []) {
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    var records: [LearnedCommandRecord] {
        recordsByID.values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            let left = $0.rankingScore()
            let right = $1.rankingScore()
            if left != right { return left > right }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    @discardableResult
    func observe(
        block: TerminalCommandBlock,
        context: TerminalExecutionContext,
        now: Date = Date()
    ) -> LearnedCommandRecord? {
        guard context.confidence == .observed,
              LearnedCommandEligibility.accepts(block) else { return nil }
        let command = LearnedCommandEligibility.normalizedCommand(block.command)
        let id = Self.recordID(command: command, context: context)
        let succeeded = block.commandLifecycleState == .succeeded
        let failed = block.commandLifecycleState == .failed
        guard succeeded || failed else { return nil }

        if failed,
           let previousFailure = recordsByID[id]?.lastFailureAt,
           now.timeIntervalSince(previousFailure) < Self.rapidFailureWindow {
            return nil
        }

        var record = recordsByID[id] ?? LearnedCommandRecord(
            id: id,
            command: command,
            context: context,
            category: LearnedCommandClassifier.category(for: command),
            observationCount: 0,
            successCount: 0,
            failureCount: 0,
            firstSeenAt: now,
            lastSeenAt: now,
            lastFailureAt: nil,
            lastExecutedAt: nil,
            isPinned: false,
            isDismissed: false
        )
        record.context = context
        record.observationCount += 1
        record.successCount += succeeded ? 1 : 0
        record.failureCount += failed ? 1 : 0
        record.lastSeenAt = now
        if failed { record.lastFailureAt = now }
        recordsByID[id] = record
        return record
    }

    func setPinned(_ pinned: Bool, id: String) {
        guard var record = recordsByID[id] else { return }
        record.isPinned = pinned
        record.isDismissed = false
        recordsByID[id] = record
    }

    func dismiss(id: String) {
        guard var record = recordsByID[id] else { return }
        record.isDismissed = true
        record.isPinned = false
        recordsByID[id] = record
    }

    func remove(id: String) {
        recordsByID[id] = nil
    }

    func markExecuted(id: String, now: Date = Date()) {
        guard var record = recordsByID[id] else { return }
        record.lastExecutedAt = now
        recordsByID[id] = record
    }

    static func recordID(command: String, context: TerminalExecutionContext) -> String {
        let material = command + "\u{1E}" + context.learningKey
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LearnedCommandStore {
    private static let fileName = "learned-commands.json"
    private static let maxRecords = 240
    private static let saveQueue = DispatchQueue(label: "im.some.museterm.learned-commands.save", qos: .utility)
    private static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QTerm", isDirectory: true)
            .appendingPathComponent("LearnedCommands", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    static var blacklistFileURL: URL {
        directory.appendingPathComponent("blacklisted-commands.json")
    }

    static func load() -> [LearnedCommandRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return prepared(try decoder.decode([LearnedCommandRecord].self, from: Data(contentsOf: fileURL)))
        } catch {
            NSLog("QTerm learned command load failed: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ records: [LearnedCommandRecord]) {
        write(prepared(records), directory: directory)
    }

    static func saveAsync(_ records: [LearnedCommandRecord]) {
        let records = prepared(records)
        let directory = directory
        saveQueue.async {
            write(records, directory: directory)
        }
    }

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        return previous
    }

    private static func prepared(_ records: [LearnedCommandRecord]) -> [LearnedCommandRecord] {
        Array(records.sorted { $0.lastSeenAt > $1.lastSeenAt }.prefix(maxRecords))
    }

    private static func write(_ records: [LearnedCommandRecord], directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(
                to: directory.appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            NSLog("QTerm learned command save failed: \(error.localizedDescription)")
        }
    }
}

/// 被「拉黑」的命令：无论执行多少次，都不再作为常用命令建议。存于常用命令同目录，
/// 复用 LearnedCommandStore 的测试目录注入。存归一化后的命令字符串（与 record.command 同源）。
enum LearnedCommandBlacklistStore {
    static func load() -> Set<String> {
        let url = LearnedCommandStore.blacklistFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
        } catch {
            NSLog("QTerm learned command blacklist load failed: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ commands: Set<String>) {
        let url = LearnedCommandStore.blacklistFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(commands.sorted()).write(to: url, options: .atomic)
        } catch {
            NSLog("QTerm learned command blacklist save failed: \(error.localizedDescription)")
        }
    }
}
