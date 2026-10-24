import Darwin
import Foundation

/// Separate from the user's explicit, recreatable configuration snapshot.
/// Contains identity and layout only, never environment, capability or terminal text.
struct TerminalRuntimeWorkspaceRecord: Codable {
    var schemaVersion = 1
    let workspaceID: UUID
    let snapshot: TerminalWorkspaceSnapshot
    let detachedIDs: [UUID]

    func validate() throws {
        let ids = snapshot.tabs.compactMap(\.terminalID)
        guard schemaVersion == 1, ids.count == snapshot.tabs.count, ids.count <= TerminalRuntimeLimits.maximumSessions,
              Set(ids).count == ids.count, Set(detachedIDs).count == detachedIDs.count,
              Set(detachedIDs).isSubset(of: Set(ids)),
              snapshot.tabs.allSatisfy({ tab in
                  (tab.kind != .ssh || tab.sshProfile != nil)
                      && (tab.runtimeAttachOnly != true || (tab.runtimeGeneration != nil && tab.runtimeRequiresExisting == true))
                      && (tab.runtimeRenderedCursor == nil || tab.runtimeRenderedCursor?.generation == tab.runtimeGeneration)
                      && tab.localProfile?.environment.isEmpty != false
                      && tab.localProfile?.startupCommands.isEmpty != false
                      && tab.localProfile?.customPrompt.isEmpty != false
                      && tab.sshProfile?.extraOptions.isEmpty != false
                      && tab.sshProfile?.startupCommands.isEmpty != false
              }) else {
            throw TerminalProjectLayoutError.invalidLayout
        }
        _ = try snapshot.restoredProjectLayout(terminalIDs: ids, defaultName: L10n.string("project.default"))
    }
}

struct TerminalRuntimeWorkspaceStore {
    static let maximumRecordBytes = 1_048_576
    let directory: URL

    init(root: URL = TerminalRuntimeService.rootDirectory) {
        directory = root.appendingPathComponent("workspaces", isDirectory: true)
    }

    func save(_ record: TerminalRuntimeWorkspaceRecord) throws {
        try record.validate()
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw TerminalProjectLayoutError.invalidLayout }
        try TerminalToolPrivateWriter.write(data, to: url(record.workspaceID))
    }

    func remove(_ id: UUID) throws {
        try prepare()
        let path = url(id).path
        guard unlink(path) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }
    }

    func recordIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func load(_ id: UUID) throws -> TerminalRuntimeWorkspaceRecord {
        try prepare()
        let descriptor = open(url(id).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = Darwin.stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_mode & 0o077 == 0,
              attributes.st_size <= Self.maximumRecordBytes else { throw CocoaError(.fileReadNoPermission) }
        let data = try file.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TerminalRuntimeWorkspaceRecord.self, from: data)
        guard record.workspaceID == id else { throw CocoaError(.fileReadCorruptFile) }
        try record.validate()
        return record
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var attributes = Darwin.stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
