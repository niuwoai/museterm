import Foundation

enum TerminalWorkingDirectory {
    static func normalizedExistingDirectory(_ directory: String?) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return nil
        }

        let expanded = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return expanded
    }
}

struct TerminalWorkspaceSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        enum Kind: String, Codable {
            case local
            case ssh
        }

        var kind: Kind
        var localDirectory: String?
        var sshProfile: SSHConnectionProfile?

        static func local(directory: String?) -> Tab {
            Tab(kind: .local, localDirectory: directory, sshProfile: nil)
        }

        static func ssh(profile: SSHConnectionProfile) -> Tab {
            Tab(kind: .ssh, localDirectory: nil, sshProfile: profile.normalized)
        }
    }

    var schemaVersion: Int
    var appVersion: String
    var savedAt: Date
    var selectedIndex: Int
    var tabs: [Tab]

    init(
        schemaVersion: Int = 1,
        appVersion: String = AppVersion.value,
        savedAt: Date = Date(),
        selectedIndex: Int,
        tabs: [Tab]
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.savedAt = savedAt
        self.selectedIndex = selectedIndex
        self.tabs = tabs
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
