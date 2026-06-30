import Foundation
import Security

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
        case bytes
        case requiresEchoOff
        case protectedBytesReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        delayMilliseconds = try container.decode(Int.self, forKey: .delayMilliseconds)
        bytes = try container.decodeIfPresent([UInt8].self, forKey: .bytes) ?? []
        requiresEchoOff = try container.decodeIfPresent(Bool.self, forKey: .requiresEchoOff) ?? false
        protectedBytesReference = try container.decodeIfPresent(String.self, forKey: .protectedBytesReference)
        transientProtectedBytes = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try container.encode(requiresEchoOff ? [] : bytes, forKey: .bytes)
        try container.encode(requiresEchoOff, forKey: .requiresEchoOff)
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
        let encoded = MuseTermKeychain.load(account: protectedBytesReference)
        guard let data = Data(base64Encoded: encoded) else { return [] }
        let bytes = Array(data)
        cache[protectedBytesReference] = bytes
        return bytes
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
}

final class TerminalShortcutRecorder {
    private let startedAt: Date
    private var lastRecordedInputAt: Date
    private(set) var events: [TerminalShortcutEvent] = []
    private(set) var hasProtectedInput = false
    private var totalRecordedBytes = 0

    private let maxEvents = 4_000
    private let maxRecordedBytes = 64 * 1024

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        lastRecordedInputAt = startedAt
    }

    func record(data: [UInt8], echoEnabled: Bool, now: Date = Date()) {
        guard !data.isEmpty else { return }
        guard events.count < maxEvents, totalRecordedBytes < maxRecordedBytes else { return }

        let remainingBytes = maxRecordedBytes - totalRecordedBytes
        let safeBytes = Array(data.prefix(remainingBytes))
        guard !safeBytes.isEmpty else { return }

        let delay = max(0, Int(now.timeIntervalSince(lastRecordedInputAt) * 1000))
        if !echoEnabled {
            hasProtectedInput = true
        }
        events.append(
            TerminalShortcutEvent(
                delayMilliseconds: min(delay, 300_000),
                bytes: echoEnabled ? safeBytes : [],
                requiresEchoOff: !echoEnabled,
                transientProtectedBytes: echoEnabled ? [] : safeBytes
            )
        )
        totalRecordedBytes += safeBytes.count
        lastRecordedInputAt = now
    }

    func finish(title: String, id: UUID = UUID(), finishedAt: Date = Date()) -> TerminalShortcut? {
        guard !events.isEmpty else { return nil }
        return TerminalShortcut(
            id: id,
            title: title,
            createdAt: startedAt,
            updatedAt: finishedAt,
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            events: events,
            hasProtectedInput: hasProtectedInput
        ).normalized
    }
}

enum TerminalShortcutStore {
    private static let maxShortcuts = 24
    private static let fileName = "shortcuts.json"
    private static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("TerminalShortcuts", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return normalized(try decoder.decode([TerminalShortcut].self, from: data))
        } catch {
            NSLog("MuseTerm shortcut load failed: \(error.localizedDescription)")
            return []
        }
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

    nonisolated static func deleteProtectedInputs(for shortcut: TerminalShortcut) {
        for event in shortcut.events {
            if let account = event.protectedBytesReference, !account.isEmpty {
                MuseTermKeychain.delete(account: account)
            } else if event.requiresEchoOff {
                MuseTermKeychain.delete(account: protectedInputAccount(shortcutID: shortcut.id, eventID: event.id))
            }
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
                MuseTermKeychain.save(Data(event.transientProtectedBytes).base64EncodedString(), account: account)
            }
            prepared.protectedBytesReference = account
            prepared.transientProtectedBytes = []
            prepared.bytes = []
            return prepared
        }
        return copy
    }

    nonisolated private static func protectedInputAccount(shortcutID: UUID, eventID: UUID) -> String {
        "terminal-shortcut/\(shortcutID.uuidString)/\(eventID.uuidString)"
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        return previous
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

    nonisolated static func save(_ secret: String, account: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            delete(account: account)
            return
        }

        if testStorage != nil {
            testStorage?[account] = trimmed
            return
        }
        if isRunningUnderXCTest {
            xctestStorage[account] = trimmed
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static func load(account: String) -> String {
        if let testStorage {
            return testStorage[account] ?? ""
        }
        if isRunningUnderXCTest {
            return xctestStorage[account] ?? ""
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
        if testStorage != nil {
            testStorage?.removeValue(forKey: account)
            return
        }
        if isRunningUnderXCTest {
            xctestStorage.removeValue(forKey: account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
