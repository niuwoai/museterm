import Foundation

struct TerminalToolLocation {
    let root: URL
    var stateFile: URL { root.appendingPathComponent("state.json") }
    var requestDirectory: URL { root.appendingPathComponent("requests", isDirectory: true) }
    var responseDirectory: URL { root.appendingPathComponent("responses", isDirectory: true) }
    var runtimeFile: URL { root.appendingPathComponent("runtime.json") }

    func prepare() throws {
        for directory in [root, requestDirectory, responseDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}
