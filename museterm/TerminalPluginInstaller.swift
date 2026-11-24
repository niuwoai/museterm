import Foundation

/// Runs `npm install` only after the package itself has already been rejected for lifecycle scripts.
/// The command is fixed: development dependencies are omitted and every lifecycle script is ignored.
enum TerminalPluginInstaller {
    static let arguments = ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"]

    static func installDependencies(in directory: URL, nodeExecutable: URL) throws {
        let npm = nodeExecutable.deletingLastPathComponent().appendingPathComponent("npm")
        guard FileManager.default.isExecutableFile(atPath: nodeExecutable.path),
              FileManager.default.isExecutableFile(atPath: npm.path) else {
            throw TerminalPluginError.failed(L10n.string("plugin.error.node"))
        }
        let process = Process()
        process.executableURL = npm
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": nodeExecutable.deletingLastPathComponent().path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "npm_config_ignore_scripts": "true",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TerminalPluginError.failed(String(reason.prefix(400)))
        }
    }
}
