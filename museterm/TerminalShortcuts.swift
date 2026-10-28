import Foundation
import CryptoKit
import Security

enum TerminalShortcutTextCodec {
    static func escapedText(from bytes: [UInt8]) -> String {
        var result = ""
        var plainBytes: [UInt8] = []

        func flushPlainBytes() {
            guard !plainBytes.isEmpty else { return }
            result += String(decoding: plainBytes, as: UTF8.self)
            plainBytes.removeAll(keepingCapacity: true)
        }

        for byte in bytes {
            switch byte {
            case 0x5C:
                flushPlainBytes()
                result += "\\\\"
            case 0x0A:
                flushPlainBytes()
                result += "\\n"
            case 0x0D:
                flushPlainBytes()
                result += "\\r"
            case 0x09:
                flushPlainBytes()
                result += "\\t"
            case 0x1B:
                flushPlainBytes()
                result += "\\e"
            case 0x7F:
                flushPlainBytes()
                result += "\\b"
            case 0x00...0x1F:
                flushPlainBytes()
                result += String(format: "\\x%02X", byte)
            default:
                plainBytes.append(byte)
            }
        }
        flushPlainBytes()
        return result
    }

    static func bytes(fromEscapedText text: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\u{0008}" {
                result.append(0x7F)
                index = text.index(after: index)
                continue
            }
            guard character == "\\" else {
                result.append(contentsOf: String(character).utf8)
                index = text.index(after: index)
                continue
            }

            let escapeStart = index
            index = text.index(after: index)
            guard index < text.endIndex else {
                result.append(0x5C)
                break
            }

            let escaped = text[index]
            switch escaped {
            case "\\":
                result.append(0x5C)
                index = text.index(after: index)
            case "n":
                result.append(0x0A)
                index = text.index(after: index)
            case "r":
                result.append(0x0D)
                index = text.index(after: index)
            case "t":
                result.append(0x09)
                index = text.index(after: index)
            case "e", "E":
                result.append(0x1B)
                index = text.index(after: index)
            case "b":
                result.append(0x7F)
                index = text.index(after: index)
            case "x":
                if let byte = hexByte(in: text, after: index) {
                    result.append(byte.value)
                    index = byte.nextIndex
                } else {
                    result.append(contentsOf: String(text[escapeStart...index]).utf8)
                    index = text.index(after: index)
                }
            default:
                result.append(0x5C)
                result.append(contentsOf: String(escaped).utf8)
                index = text.index(after: index)
            }
        }

        return result
    }

    private static func hexByte(in text: String, after escapeIndex: String.Index) -> (value: UInt8, nextIndex: String.Index)? {
        let firstIndex = text.index(after: escapeIndex)
        guard firstIndex < text.endIndex else { return nil }
        let secondIndex = text.index(after: firstIndex)
        guard secondIndex < text.endIndex else { return nil }
        let hex = String(text[firstIndex...secondIndex])
        guard let value = UInt8(hex, radix: 16) else { return nil }
        return (value, text.index(after: secondIndex))
    }
}

struct TerminalShortcutEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var delayMilliseconds: Int
    var bytes: [UInt8]
    var requiresEchoOff: Bool
    var protectedBytesReference: String?
    var transientProtectedBytes: [UInt8]

    init(
        id: UUID = UUID(),
        delayMilliseconds: Int,
        bytes: [UInt8],
        requiresEchoOff: Bool = false,
        protectedBytesReference: String? = nil,
        transientProtectedBytes: [UInt8] = []
    ) {
        self.id = id
        self.delayMilliseconds = max(0, delayMilliseconds)
        self.requiresEchoOff = requiresEchoOff
        self.bytes = requiresEchoOff ? [] : bytes
        self.protectedBytesReference = protectedBytesReference
        self.transientProtectedBytes = requiresEchoOff ? transientProtectedBytes : []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case delayMilliseconds
        case text
        case bytes
        case requiresEchoOff
        case protectedBytesReference
    }

    private enum FlexibleBytes: Decodable {
        case string(String)
        case array([UInt8])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }
            self = .array(try container.decode([UInt8].self))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        delayMilliseconds = try container.decode(Int.self, forKey: .delayMilliseconds)
        requiresEchoOff = try container.decodeIfPresent(Bool.self, forKey: .requiresEchoOff) ?? false
        if requiresEchoOff {
            bytes = []
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            bytes = TerminalShortcutTextCodec.bytes(fromEscapedText: text)
        } else if let flexibleBytes = try container.decodeIfPresent(FlexibleBytes.self, forKey: .bytes) {
            switch flexibleBytes {
            case .string(let text):
                bytes = TerminalShortcutTextCodec.bytes(fromEscapedText: text)
            case .array(let rawBytes):
                bytes = rawBytes
            }
        } else {
            bytes = []
        }
        protectedBytesReference = try container.decodeIfPresent(String.self, forKey: .protectedBytesReference)
        transientProtectedBytes = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try container.encode(requiresEchoOff, forKey: .requiresEchoOff)
        if requiresEchoOff {
            try container.encode([UInt8](), forKey: .bytes)
        } else {
            let text = TerminalShortcutTextCodec.escapedText(from: bytes)
            try container.encode(text, forKey: .text)
            try container.encode(text, forKey: .bytes)
        }
        try container.encodeIfPresent(protectedBytesReference, forKey: .protectedBytesReference)
    }

    var isPlayable: Bool {
        if requiresEchoOff {
            return !transientProtectedBytes.isEmpty || protectedBytesReference?.isEmpty == false
        }
        return !bytes.isEmpty
    }

    func resolvedBytes(cache: inout [String: [UInt8]]) -> [UInt8] {
        guard requiresEchoOff else { return bytes }
        if !transientProtectedBytes.isEmpty { return transientProtectedBytes }
        guard let protectedBytesReference, !protectedBytesReference.isEmpty else { return [] }
        if let cached = cache[protectedBytesReference] { return cached }
        if let bytes = TerminalShortcutProtectedVault.load(account: protectedBytesReference) {
            cache[protectedBytesReference] = bytes
            return bytes
        }
        let encoded = MuseTermKeychain.load(account: protectedBytesReference)
        guard let data = Data(base64Encoded: encoded) else { return [] }
        let bytes = Array(data)
        TerminalShortcutProtectedVault.save(bytes, account: protectedBytesReference)
        cache[protectedBytesReference] = bytes
        return bytes
    }

    static func terminalPlaybackBytes(from bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                result.append(0x0D)
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if byte == 0x0A {
                result.append(0x0D)
            } else {
                result.append(byte)
            }
            index += 1
        }
        return result
    }
}

struct TerminalShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationMilliseconds: Int
    var events: [TerminalShortcutEvent]
    var hasProtectedInput: Bool
    var executionContext: TerminalExecutionContext? = nil
    /// 为 true 时，本人点击和自动化回放都要先通过 Touch ID（或登录密码）。
    /// 旧录制没有这个字段，解码后保持可直接回放。
    var requiresUserAuthentication: Bool = false
    /// 为 false 时，MCP、CLI 与 AppleScript 不能回放这条录制。
    /// 本人在界面里点击不受影响。旧录制默认仍允许自动化，与既有行为一致。
    var allowsAutomationPlayback: Bool = true

    var eventCount: Int { events.count }
    var isPlayable: Bool { !events.isEmpty }

    var normalized: TerminalShortcut {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? L10n.string("shortcut.default_title") : String(trimmed.prefix(80))
        copy.durationMilliseconds = max(0, durationMilliseconds)
        copy.events = events.filter(\.isPlayable)
        copy.hasProtectedInput = copy.events.contains(where: \.requiresEchoOff)
        return copy
    }

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        durationMilliseconds: Int,
        events: [TerminalShortcutEvent],
        hasProtectedInput: Bool,
        executionContext: TerminalExecutionContext? = nil,
        requiresUserAuthentication: Bool = false,
        allowsAutomationPlayback: Bool = true
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationMilliseconds = durationMilliseconds
        self.events = events
        self.hasProtectedInput = hasProtectedInput
        self.executionContext = executionContext
        self.requiresUserAuthentication = requiresUserAuthentication
        self.allowsAutomationPlayback = allowsAutomationPlayback
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case durationMilliseconds
        case events
        case hasProtectedInput
        case executionContext
        case requiresUserAuthentication
        case allowsAutomationPlayback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
        events = try container.decode([TerminalShortcutEvent].self, forKey: .events)
        hasProtectedInput = try container.decode(Bool.self, forKey: .hasProtectedInput)
        executionContext = try container.decodeIfPresent(TerminalExecutionContext.self, forKey: .executionContext)
        requiresUserAuthentication = MuseTermScriptingPolicy.decodePlaybackFlag(
            try container.decodeIfPresent(Bool.self, forKey: .requiresUserAuthentication),
            default: false
        )
        allowsAutomationPlayback = MuseTermScriptingPolicy.decodePlaybackFlag(
            try container.decodeIfPresent(Bool.self, forKey: .allowsAutomationPlayback),
            default: true
        )
    }
}

struct TerminalShortcutStep: Codable, Equatable {
    var text: String
    var delayMilliseconds: Int?
    var sendReturn: Bool?
}

enum TerminalShortcutDraftError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case duplicateTitle(String)
    case targetNotFound(String)
    case ambiguousTarget(String)
    case protectedTarget(String)
    case noSteps
    case tooManySteps(Int)
    case stepTooLarge(Int)
    case tooManyBytes
    case delayOutOfRange(Int)

    private var key: String {
        switch self {
        case .emptyTitle: return "tools.error.shortcut_empty_title"
        case .titleTooLong: return "tools.error.shortcut_title_too_long"
        case .duplicateTitle: return "tools.error.shortcut_duplicate_title"
        case .targetNotFound: return "tools.error.shortcut_target_not_found"
        case .ambiguousTarget: return "tools.error.shortcut_ambiguous_target"
        case .protectedTarget: return "tools.error.shortcut_protected_target"
        case .noSteps: return "tools.error.shortcut_no_steps"
        case .tooManySteps: return "tools.error.shortcut_too_many_steps"
        case .stepTooLarge: return "tools.error.shortcut_step_too_large"
        case .tooManyBytes: return "tools.error.shortcut_too_many_bytes"
        case .delayOutOfRange: return "tools.error.shortcut_delay_out_of_range"
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyTitle, .titleTooLong, .noSteps, .tooManyBytes:
            return L10n.string(key)
        case .duplicateTitle(let title), .targetNotFound(let title), .ambiguousTarget(let title), .protectedTarget(let title):
            return L10n.format(key, title)
        case .tooManySteps(let limit), .stepTooLarge(let limit), .delayOutOfRange(let limit):
            return L10n.format(key, limit)
        }
    }
}

enum TerminalShortcutDraft {
    static let maxSteps = 24
    static let maxStepBytes = 4_096
    static let maxTotalBytes = 64 * 1_024
    static let maxDelayMilliseconds = 300_000

    static func make(
        title rawTitle: String,
        steps: [TerminalShortcutStep],
        replacing target: TerminalShortcut?,
        existingTitles: [String],
        requiresUserAuthentication: Bool?,
        allowsAutomationPlayback: Bool?,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> TerminalShortcut {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TerminalShortcutDraftError.emptyTitle }
        guard title.count <= 80 else { throw TerminalShortcutDraftError.titleTooLong }
        if let target, target.hasProtectedInput {
            throw TerminalShortcutDraftError.protectedTarget(target.title)
        }
        let taken = existingTitles.contains { candidate in
            candidate.localizedCaseInsensitiveCompare(title) == .orderedSame
        }
        if taken { throw TerminalShortcutDraftError.duplicateTitle(title) }

        guard !steps.isEmpty else { throw TerminalShortcutDraftError.noSteps }
        guard steps.count <= maxSteps else { throw TerminalShortcutDraftError.tooManySteps(maxSteps) }

        var events: [TerminalShortcutEvent] = []
        var totalBytes = 0
        for (offset, step) in steps.enumerated() {
            let delay = step.delayMilliseconds ?? 0
            guard (0...maxDelayMilliseconds).contains(delay) else {
                throw TerminalShortcutDraftError.delayOutOfRange(maxDelayMilliseconds)
            }
            var bytes = Array(step.text.utf8)
            if step.sendReturn ?? true {
                bytes.append(0x0D)
            }
            guard !bytes.isEmpty else { throw TerminalShortcutDraftError.noSteps }
            guard bytes.count <= maxStepBytes else { throw TerminalShortcutDraftError.stepTooLarge(maxStepBytes) }
            totalBytes += bytes.count
            guard totalBytes <= maxTotalBytes else { throw TerminalShortcutDraftError.tooManyBytes }
            events.append(
                TerminalShortcutEvent(
                    delayMilliseconds: offset == 0 ? 0 : delay,
                    bytes: bytes
                )
            )
        }

        let startedAt = now.addingTimeInterval(-Double(events.dropFirst().reduce(0) { $0 + $1.delayMilliseconds }) / 1000)
        return TerminalShortcut(
            id: target?.id ?? id,
            title: title,
            createdAt: target?.createdAt ?? startedAt,
            updatedAt: now,
            durationMilliseconds: max(0, Int(now.timeIntervalSince(startedAt) * 1000)),
            events: events,
            hasProtectedInput: false,
            requiresUserAuthentication: requiresUserAuthentication ?? target?.requiresUserAuthentication ?? false,
            allowsAutomationPlayback: allowsAutomationPlayback ?? target?.allowsAutomationPlayback ?? true
        ).normalized
    }
}

struct TerminalShortcutProtectedInput: Equatable, Identifiable {
    let shortcutID: UUID
    let shortcutTitle: String
    let eventID: UUID
    let eventIndex: Int
    let account: String

    var id: String {
        "\(shortcutID.uuidString):\(eventID.uuidString):\(account)"
    }

    var usesDefaultAccount: Bool {
        account.hasPrefix("terminal-shortcut/\(shortcutID.uuidString)/")
    }
}

final class TerminalShortcutRecorder {
    private let startedAt: Date
    private var lastRecordedInputAt: Date
    private(set) var events: [TerminalShortcutEvent] = []
    private(set) var hasProtectedInput = false
    private var totalRecordedBytes = 0
    private var pendingBytes: [UInt8] = []
    private var pendingEchoEnabled: Bool?
    private var pendingStartedAt: Date?

    private let maxEvents = 4_000
    private let maxRecordedBytes = 64 * 1024

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        lastRecordedInputAt = startedAt
    }

    func record(data: [UInt8], echoEnabled: Bool, now: Date = Date()) {
        guard !data.isEmpty else { return }
        if let pendingEchoEnabled, pendingEchoEnabled != echoEnabled {
            flushPendingInput(now: now)
        }

        for byte in data {
            guard totalRecordedBytes + pendingBytes.count < maxRecordedBytes else { break }
            if pendingBytes.isEmpty {
                pendingStartedAt = now
                pendingEchoEnabled = echoEnabled
            }
            pendingBytes.append(byte)
            if byte == 0x0D || byte == 0x0A {
                flushPendingInput(now: now)
            }
        }
    }

    private func flushPendingInput(now: Date) {
        defer {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingEchoEnabled = nil
            pendingStartedAt = nil
        }
        guard !pendingBytes.isEmpty else { return }
        appendEvent(
            bytes: pendingBytes,
            echoEnabled: pendingEchoEnabled ?? true,
            now: pendingStartedAt ?? now,
            anchor: now
        )
    }

    private func appendEvent(bytes rawBytes: [UInt8], echoEnabled: Bool, now: Date, anchor: Date? = nil) {
        guard !rawBytes.isEmpty else { return }
        guard events.count < maxEvents, totalRecordedBytes < maxRecordedBytes else { return }

        let remainingBytes = maxRecordedBytes - totalRecordedBytes
        let safeBytes = Array(rawBytes.prefix(remainingBytes))
        guard !safeBytes.isEmpty else { return }

        let delay = max(0, Int(now.timeIntervalSince(lastRecordedInputAt) * 1000))
        hasProtectedInput = hasProtectedInput || !echoEnabled
        events.append(
            TerminalShortcutEvent(
                delayMilliseconds: min(delay, 300_000),
                bytes: echoEnabled ? safeBytes : [],
                requiresEchoOff: !echoEnabled,
                transientProtectedBytes: echoEnabled ? [] : safeBytes
            )
        )
        totalRecordedBytes += safeBytes.count
        lastRecordedInputAt = anchor ?? now
    }

    func finish(
        title: String,
        id: UUID = UUID(),
        executionContext: TerminalExecutionContext? = nil,
        finishedAt: Date = Date()
    ) -> TerminalShortcut? {
        flushPendingInput(now: finishedAt)
        guard !events.isEmpty else { return nil }
        return TerminalShortcut(
            id: id,
            title: title,
            createdAt: startedAt,
            updatedAt: finishedAt,
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            events: events,
            hasProtectedInput: hasProtectedInput,
            executionContext: executionContext
        ).normalized
    }
}

enum TerminalShortcutStore {
    private static let maxShortcuts = 24
    private static let fileName = "shortcuts.json"
    private static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return sharedDirectory
    }

    private static var legacyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("TerminalShortcuts", isDirectory: true)
    }

    private static var sharedDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("terminal-shortcuts", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    private static var legacyFileURL: URL {
        legacyDirectory.appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> [TerminalShortcut] {
        if let shortcuts = load(from: fileURL) {
            return normalized(shortcuts)
        }
        guard directoryOverride == nil,
              let legacyShortcuts = load(from: legacyFileURL),
              !legacyShortcuts.isEmpty else { return [] }
        save(legacyShortcuts)
        return normalized(legacyShortcuts)
    }

    static func save(_ shortcuts: [TerminalShortcut]) {
        let prepared = normalized(shortcuts).map { prepareForPersistence($0) }
        do {
            try ensureDirectory()
            let data = try encoder.encode(prepared)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MuseTerm shortcut save failed: \(error.localizedDescription)")
        }
    }

    static func editableText(for shortcuts: [TerminalShortcut]) -> String {
        let prepared = normalized(shortcuts).map { prepareForPersistence($0) }
        guard let data = try? encoder.encode(prepared) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeEditableText(_ text: String) throws -> [TerminalShortcut] {
        let data = Data(text.utf8)
        return normalized(try decoder.decode([TerminalShortcut].self, from: data))
    }

    static func protectedInputs(fromEditableText text: String) throws -> [TerminalShortcutProtectedInput] {
        try protectedInputs(in: decodeEditableText(text))
    }

    static func protectedInputs(in shortcuts: [TerminalShortcut]) -> [TerminalShortcutProtectedInput] {
        normalized(shortcuts).flatMap { shortcut in
            shortcut.events.enumerated().compactMap { offset, event in
                guard event.requiresEchoOff else { return nil }
                let account = protectedInputAccount(for: event, shortcutID: shortcut.id)
                guard !account.isEmpty else { return nil }
                return TerminalShortcutProtectedInput(
                    shortcutID: shortcut.id,
                    shortcutTitle: shortcut.title,
                    eventID: event.id,
                    eventIndex: offset,
                    account: account
                )
            }
        }
    }

    @discardableResult
    static func saveProtectedInput(_ secret: String, account: String, appendingReturn: Bool) -> Bool {
        guard !account.isEmpty else { return false }
        guard !secret.isEmpty else {
            deleteProtectedInput(account: account)
            return true
        }
        var bytes = Array(secret.utf8)
        if appendingReturn {
            bytes.append(0x0D)
        }
        TerminalShortcutProtectedVault.save(bytes, account: account)
        return true
    }

    static func protectedInputHasValue(account: String) -> Bool {
        if TerminalShortcutProtectedVault.load(account: account)?.isEmpty == false {
            return true
        }
        return MuseTermKeychain.load(account: account).isEmpty == false
    }

    static func deleteProtectedInput(account: String) {
        TerminalShortcutProtectedVault.delete(account: account)
        MuseTermKeychain.delete(account: account)
    }

    static func deleteProtectedInputs(removedFrom oldShortcuts: [TerminalShortcut], keeping newShortcuts: [TerminalShortcut]) {
        let keptAccounts = Set(protectedInputAccounts(in: newShortcuts))
        for account in protectedInputAccounts(in: oldShortcuts) where !keptAccounts.contains(account) {
            deleteProtectedInput(account: account)
        }
    }

    static func deleteProtectedInputs(for shortcut: TerminalShortcut) {
        for account in protectedInputAccounts(in: [shortcut]) {
            deleteProtectedInput(account: account)
        }
    }

    private static func normalized(_ shortcuts: [TerminalShortcut]) -> [TerminalShortcut] {
        Array(
            shortcuts
                .map(\.normalized)
                .filter(\.isPlayable)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maxShortcuts)
        )
    }

    private static func prepareForPersistence(_ shortcut: TerminalShortcut) -> TerminalShortcut {
        var copy = shortcut.normalized
        copy.events = copy.events.map { event in
            guard event.requiresEchoOff else { return event }
            var prepared = event
            let account = event.protectedBytesReference ?? protectedInputAccount(shortcutID: shortcut.id, eventID: event.id)
            if !event.transientProtectedBytes.isEmpty {
                TerminalShortcutProtectedVault.save(event.transientProtectedBytes, account: account)
            }
            prepared.protectedBytesReference = account
            prepared.transientProtectedBytes = []
            prepared.bytes = []
            return prepared
        }
        return copy
    }

    private static func protectedInputAccounts(in shortcuts: [TerminalShortcut]) -> [String] {
        shortcuts.flatMap { shortcut in
            shortcut.events.compactMap { event in
                guard event.requiresEchoOff else { return nil }
                return protectedInputAccount(for: event, shortcutID: shortcut.id)
            }
        }
    }

    private static func protectedInputAccount(for event: TerminalShortcutEvent, shortcutID: UUID) -> String {
        if let account = event.protectedBytesReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !account.isEmpty {
            return account
        }
        return protectedInputAccount(shortcutID: shortcutID, eventID: event.id)
    }

    nonisolated private static func protectedInputAccount(shortcutID: UUID, eventID: UUID) -> String {
        "terminal-shortcut/\(shortcutID.uuidString)/\(eventID.uuidString)"
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func load(from url: URL) -> [TerminalShortcut]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([TerminalShortcut].self, from: data)
        } catch {
            NSLog("MuseTerm shortcut load failed at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        TerminalShortcutProtectedVault.resetInMemoryKeyForTests()
        return previous
    }
}

enum TerminalShortcutProtectedVault {
    private static let keyFileName = "protected-vault.key"
    private static let dataFileName = "protected-vault.json"
    private static var cachedKeyData: Data?

    private struct Payload: Codable {
        var version: Int
        var entries: [String: String]
    }

    private static var keyURL: URL {
        TerminalShortcutStore.directory.appendingPathComponent(keyFileName)
    }

    private static var dataURL: URL {
        TerminalShortcutStore.directory.appendingPathComponent(dataFileName)
    }

    static func save(_ bytes: [UInt8], account: String) {
        guard !bytes.isEmpty, !account.isEmpty else {
            delete(account: account)
            return
        }
        do {
            var payload = try loadPayload()
            let sealed = try AES.GCM.seal(Data(bytes), using: key())
            guard let combined = sealed.combined else { return }
            payload.entries[account] = combined.base64EncodedString()
            try savePayload(payload)
        } catch {
            NSLog("MuseTerm protected shortcut save failed: \(error.localizedDescription)")
        }
    }

    static func load(account: String) -> [UInt8]? {
        guard !account.isEmpty else { return nil }
        do {
            let payload = try loadPayload()
            guard let encoded = payload.entries[account],
                  let combined = Data(base64Encoded: encoded) else { return nil }
            let sealed = try AES.GCM.SealedBox(combined: combined)
            return Array(try AES.GCM.open(sealed, using: key()))
        } catch {
            NSLog("MuseTerm protected shortcut load failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func delete(account: String) {
        guard !account.isEmpty else { return }
        do {
            var payload = try loadPayload()
            payload.entries.removeValue(forKey: account)
            try savePayload(payload)
        } catch {
            NSLog("MuseTerm protected shortcut delete failed: \(error.localizedDescription)")
        }
    }

    private static func key() throws -> SymmetricKey {
        if let cachedKeyData, cachedKeyData.count == 32 {
            return SymmetricKey(data: cachedKeyData)
        }
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
            cachedKeyData = existing
            return SymmetricKey(data: existing)
        }
        try ensureDirectory()
        var generated = Data(count: 32)
        let status = generated.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        try generated.write(to: keyURL, options: .atomic)
        try setOwnerOnlyPermissions(at: keyURL, mode: 0o600)
        cachedKeyData = generated
        return SymmetricKey(data: generated)
    }

    private static func loadPayload() throws -> Payload {
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            return Payload(version: 1, entries: [:])
        }
        let data = try Data(contentsOf: dataURL)
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private static func savePayload(_ payload: Payload) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: dataURL, options: .atomic)
        try setOwnerOnlyPermissions(at: dataURL, mode: 0o600)
    }

    private static func ensureDirectory() throws {
        let directory = TerminalShortcutStore.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setOwnerOnlyPermissions(at: directory, mode: 0o700)
    }

    private static func setOwnerOnlyPermissions(at url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func resetInMemoryKeyForTests() {
        cachedKeyData = nil
    }
}

enum MuseTermKeychain {
    nonisolated private static let service = "com.museterm.credentials"
    nonisolated(unsafe) private static var testStorage: [String: String]?
    nonisolated(unsafe) private static var xctestStorage: [String: String] = [:]

    nonisolated private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func _useTestStorage(_ enabled: Bool) {
        testStorage = enabled ? [:] : nil
    }

    @discardableResult
    nonisolated static func save(_ secret: String, account: String) -> Bool {
        save(secret, account: account, serviceName: service)
    }

    @discardableResult
    nonisolated static func save(_ secret: String, account: String, serviceName: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            delete(account: account, serviceName: serviceName)
            return true
        }

        if testStorage != nil {
            testStorage?[storageKey(serviceName: serviceName, account: account)] = trimmed
            return true
        }
        if isRunningUnderXCTest {
            xctestStorage[storageKey(serviceName: serviceName, account: account)] = trimmed
            return true
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess,
           load(account: account, serviceName: serviceName) == trimmed {
            return true
        }
        if status != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        return load(account: account, serviceName: serviceName) == trimmed
    }

    nonisolated static func load(account: String) -> String {
        load(account: account, serviceName: service)
    }

    nonisolated static func load(account: String, serviceName: String) -> String {
        if let testStorage {
            return testStorage[storageKey(serviceName: serviceName, account: account)] ?? ""
        }
        if isRunningUnderXCTest {
            return xctestStorage[storageKey(serviceName: serviceName, account: account)] ?? ""
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    nonisolated static func delete(account: String) {
        delete(account: account, serviceName: service)
    }

    nonisolated static func delete(account: String, serviceName: String) {
        if testStorage != nil {
            testStorage?.removeValue(forKey: storageKey(serviceName: serviceName, account: account))
            return
        }
        if isRunningUnderXCTest {
            xctestStorage.removeValue(forKey: storageKey(serviceName: serviceName, account: account))
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated private static func storageKey(serviceName: String, account: String) -> String {
        "\(serviceName)\u{1F}\(account)"
    }
}
