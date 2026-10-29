import Darwin
import Foundation

/// Terminal-scoped, status-only bootstrap. Never included in public tool snapshots.
final class TerminalNativeAgentContext {
    struct Descriptor: Codable {
        let protocolVersion: Int
        let tabID: UUID
        let root: String
        let token: String
    }

    private(set) var token: String?
    private(set) var file: URL?

    func prepare(tabID: UUID, root: URL) throws -> URL {
        if let file, token != nil { return file }
        let directory = root.appendingPathComponent("native-agent-contexts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var attributes = Darwin.stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let token = UUID().uuidString + UUID().uuidString
        let file = directory.appendingPathComponent("\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(Descriptor(protocolVersion: 1, tabID: tabID, root: root.path, token: token))
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
        self.token = token
        self.file = file
        return file
    }

    func authorizes(_ candidate: String?) -> Bool {
        guard let token, let candidate, token.utf8.count == candidate.utf8.count else { return false }
        return zip(token.utf8, candidate.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func invalidate() {
        token = nil
        if let file {
            do { try FileManager.default.removeItem(at: file) }
            catch { if FileManager.default.fileExists(atPath: file.path) { NSLog("MuseTerm could not remove native status context") } }
        }
        file = nil
    }

    deinit { invalidate() }
}
