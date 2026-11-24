import Foundation

/// The Seatbelt profile used before the first plugin process. A named profile such as `no-network`
/// exits 137, so the rules are written in full. `(deny default)` wins over a later allow of the
/// same operation, which is why the home-directory denial is narrowed and then reopened.
enum TerminalPluginSandbox {
    struct Paths: Equatable {
        var pluginDirectory: String
        var temporaryDirectory: String
        var shortcutDirectory: String
        var toolBridgeDirectory: String
        var homeDirectory: String
    }

    static func profile(for paths: Paths) -> String {
        let home = paths.homeDirectory
        return """
        (version 1)
        (deny default)
        (allow file-read*)
        (allow file-read-metadata)
        (allow file-write*
            (subpath \(quoted(paths.pluginDirectory)))
            (subpath \(quoted(paths.temporaryDirectory))))
        (allow process-exec)
        (allow process-fork)
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow ipc-posix-shm)

        (deny file-read* file-write*
            (subpath \(quoted(paths.shortcutDirectory)))
            (subpath \(quoted(paths.toolBridgeDirectory)))
            (subpath \(quoted(home + "/Library/Keychains")))
            (subpath \(quoted(home + "/Library/Containers"))))
        (deny file-read*
            (regex "^\(escaped(home))($|/.*)$"))
        (allow file-read*
            (subpath \(quoted(paths.pluginDirectory)))
            (subpath \(quoted(paths.temporaryDirectory))))

        (deny network*)
        (deny system-socket)
        """
    }

    static func paths(pluginDirectory: URL, temporaryDirectory: URL) -> Paths {
        Paths(
            pluginDirectory: pluginDirectory.path,
            temporaryDirectory: temporaryDirectory.path,
            shortcutDirectory: TerminalShortcutStore.directory.path,
            toolBridgeDirectory: TerminalToolPaths.rootDirectory.path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Scheme regular expressions are ordinary double-quoted strings. A `#"..."#` marker is a
    /// comment to Seatbelt, so the rule matches nothing. A bare slash is itself; escaping it does too.
    private static func escaped(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if ".\\+*?[^]$(){}|".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }
}
