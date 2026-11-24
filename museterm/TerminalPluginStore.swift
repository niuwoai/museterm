import Combine
import Foundation

/// Installed plugins live under Application Support, one directory each, mode 0700.
/// A plugin stays disabled until the user confirms its permissions.
final class TerminalPluginStore: ObservableObject {
    static let shared = TerminalPluginStore()

    @Published private(set) var plugins: [TerminalPlugin] = []
    @Published var lastError = ""

    private let directoryOverride: URL?
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        directoryOverride = directory
        reload()
    }

    var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    func reload() {
        plugins = load()
    }

    /// Copies a local directory. The copy is marked unsigned and stays disabled.
    func installLocal(from source: URL) throws {
        let package = try Data(contentsOf: source.appendingPathComponent("package.json"))
        let draft = try Self.draft(from: package)
        let destination = directory.appendingPathComponent(Self.directoryName(for: draft.id), isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw TerminalPluginError.failed(L10n.format("plugin.error.already_installed", draft.displayName))
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try writeState(id: draft.id, enabled: false, source: "local")
        reload()
    }

    /// Installs one package named by the catalog, with `--omit=dev --ignore-scripts`.
    /// A lifecycle script or a file/git dependency is rejected before npm runs.
    func installFromCatalog(packageName: String, version: String, catalogDirectory: URL, nodeExecutable: URL) throws {
        let source = catalogDirectory.appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
        let package = try Data(contentsOf: source.appendingPathComponent("package.json"))
        let draft = try Self.draft(from: package)
        guard draft.id == packageName else {
            throw TerminalPluginError.failed(L10n.format("plugin.error.invalid_response", packageName))
        }
        let destination = directory.appendingPathComponent(Self.directoryName(for: draft.id), isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw TerminalPluginError.failed(L10n.format("plugin.error.already_installed", draft.displayName))
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: source, to: staging)
        try TerminalPluginInstaller.installDependencies(
            in: staging,
            nodeExecutable: nodeExecutable
        )
        let installed = try Data(contentsOf: staging.appendingPathComponent("package.json"))
        _ = try Self.draft(from: installed)
        try fileManager.moveItem(at: staging, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try writeState(id: draft.id, enabled: false, source: "catalog:\(version)")
        reload()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard var state = readState(), state[id] != nil else { return }
        state[id]?.enabled = enabled
        try? write(state)
        reload()
    }

    func remove(id: String) {
        let destination = directory.appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
        try? fileManager.removeItem(at: destination)
        if var state = readState() {
            state.removeValue(forKey: id)
            try? write(state)
        }
        reload()
    }

    func enabledPlugins(with permission: String) -> [TerminalPlugin] {
        plugins.filter { $0.enabled && $0.permissions.contains(permission) }
    }

    private func load() -> [TerminalPlugin] {
        let state = readState() ?? [:]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("package.json")),
                  case .success(let draft) = TerminalPluginManifest.read(packageData: data) else { return nil }
            let record = state[draft.id]
            return TerminalPlugin(
                id: draft.id,
                directory: entry,
                displayName: draft.displayName,
                version: draft.version,
                permissions: draft.permissions,
                commands: draft.commands,
                preferences: draft.preferences,
                suggestExport: draft.suggestExport.isEmpty ? nil : draft.suggestExport,
                recordingExport: draft.recordingExport.isEmpty ? nil : draft.recordingExport,
                enabled: record?.enabled ?? false,
                source: record?.source ?? "local",
                entry: draft.entry
            )
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private struct PluginState: Codable {
        var enabled: Bool
        var source: String
    }

    private func readState() -> [String: PluginState]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else { return nil }
        return try? JSONDecoder().decode([String: PluginState].self, from: data)
    }

    private func writeState(id: String, enabled: Bool, source: String) throws {
        var state = readState() ?? [:]
        state[id] = PluginState(enabled: enabled, source: source)
        try write(state)
    }

    private func write(_ state: [String: PluginState]) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    private static func draft(from data: Data) throws -> TerminalPluginManifest.PluginDraft {
        switch TerminalPluginManifest.read(packageData: data) {
        case .success(let draft): return draft
        case .failure(let failure):
            throw TerminalPluginError.failed(failure.issues.map { "\($0.path) \($0.message)" }.joined(separator: "\n"))
        }
    }

    /// A package scope separator cannot be a path component.
    static func directoryName(for packageID: String) -> String {
        packageID.replacingOccurrences(of: "/", with: "__")
    }
}
