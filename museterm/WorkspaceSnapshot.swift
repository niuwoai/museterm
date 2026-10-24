import Foundation

struct TerminalWorkspaceSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        enum Kind: String, Codable {
            case local
            case ssh
        }

        var kind: Kind
        var localDirectory: String?
        var sshProfile: SSHConnectionProfile?
        var localProfile: TerminalProfile?
        var terminalID: UUID? = nil
        var runtimeGeneration: UUID? = nil
        var runtimeRequiresExisting: Bool? = nil
        var runtimeRenderedCursor: TerminalRuntimeOutputCursor? = nil
        var runtimeAttachOnly: Bool? = nil

        static func local(directory: String?, profile: TerminalProfile? = nil) -> Tab {
            Tab(kind: .local, localDirectory: directory, sshProfile: nil, localProfile: profile?.normalized)
        }

        static func ssh(profile: SSHConnectionProfile) -> Tab {
            Tab(kind: .ssh, localDirectory: nil, sshProfile: profile.normalized, localProfile: nil)
        }
    }

    var schemaVersion: Int
    var appVersion: String
    var savedAt: Date
    var selectedIndex: Int
    var tabs: [Tab]
    var projectLayout: TerminalProjectLayout? = nil

    init(
        schemaVersion: Int = 1,
        appVersion: String = AppVersion.value,
        savedAt: Date = Date(),
        selectedIndex: Int,
        tabs: [Tab],
        projectLayout: TerminalProjectLayout? = nil
    ) {
        self.schemaVersion = projectLayout == nil ? schemaVersion : 2
        self.appVersion = appVersion
        self.savedAt = savedAt
        self.selectedIndex = selectedIndex
        self.tabs = tabs
        self.projectLayout = projectLayout
    }
}

enum TerminalWorkspaceSnapshotError: LocalizedError {
    case emptyWorkspace
    case missingSnapshot
    case unsupportedTab

    var errorDescription: String? {
        switch self {
        case .emptyWorkspace:
            return L10n.string("workspace.error.empty")
        case .missingSnapshot:
            return L10n.string("workspace.error.missing")
        case .unsupportedTab:
            return L10n.string("workspace.error.unsupported_tab")
        }
    }
}

enum TerminalWorkspaceSnapshotStore {
    private static var directoryOverride: URL?

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        return previous
    }
    static func save(_ snapshot: TerminalWorkspaceSnapshot) throws {
        let url = try snapshotURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func load() throws -> TerminalWorkspaceSnapshot {
        let url = try snapshotURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TerminalWorkspaceSnapshotError.missingSnapshot
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(TerminalWorkspaceSnapshot.self, from: data)
    }

    private static func snapshotURL() throws -> URL {
        if let directoryOverride { return directoryOverride.appendingPathComponent("last-workspace.json") }
        #if DEBUG
        if TerminalToolPaths.isIsolatedTesting {
            return TerminalToolPaths.rootDirectory.appendingPathComponent("last-workspace.json")
        }
        #endif
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("last-workspace.json")
    }
}
