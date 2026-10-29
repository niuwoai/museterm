#if DEBUG
import Darwin
import Foundation

/// Opt-in native QA only. Credentials never enter the system keychain and
/// cannot authorize a separate regular MuseTerm process.
enum TerminalToolAccessTestFixture {
    struct Credentials: Codable {
        let clientID: String
        let token: String
    }
    private static let maximumBytes = 1_024
    static let fileName = "project-tool-fixture.json"

    static func configure(_ preferences: TerminalPreferences) {
        guard ProcessInfo.processInfo.environment["MUSETERM_GUI_TOOL_FIXTURE"] == "1",
              Bundle.main.bundleIdentifier?.hasPrefix("im.some.museterm.goaltests.") == true else { return }
        // Even an invalid opted-in fixture stays disconnected from real keys.
        MuseTermKeychain._useTestStorage(true)
        preferences.toolBridgeWritesEnabled = false
        do {
            let credentials = try load(root: TerminalToolPaths.rootDirectory)
            guard MuseTermKeychain.save(credentials.token, account: credentials.clientID,
                serviceName: TerminalToolAccess.keychainServiceName) else { throw CocoaError(.fileReadUnknown) }
            preferences.toolBridgeWritesEnabled = true
        } catch { NSLog("MuseTerm isolated tool credential fixture rejected") }
    }

    static func load(root: URL) throws -> Credentials {
        let parent = root.deletingLastPathComponent()
        // Foundation may canonicalize /private/tmp to /tmp on macOS. Check
        // the fixed directory structure and lstat each owned component instead.
        guard root.lastPathComponent == "Tools", parent.lastPathComponent.hasPrefix("museterm-native-qa-"),
              parent.deletingLastPathComponent().path == "/private/tmp" else { throw CocoaError(.fileReadNoPermission) }
        for directory in [root, parent] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        let fd = open(root.appendingPathComponent(fileName).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= maximumBytes else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try reader.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Credentials.self, from: data)
        guard value.clientID.hasPrefix("museterm-qa-"), value.clientID.utf8.count <= 80,
              value.clientID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              value.token.utf8.count == 64, value.token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
#endif
