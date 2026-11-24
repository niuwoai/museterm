import Foundation

/// The catalog is a separate repository. Adding a plugin means a pull request there, not a change here.
enum TerminalPluginCatalog {
    struct Entry: Equatable, Decodable {
        let name: String
        let version: String
        let description: String
    }

    struct Index: Equatable {
        let directory: URL
        let plugins: [Entry]
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Sites", isDirectory: true)
        .appendingPathComponent("museterm-plugins-manifest", isDirectory: true)

    static func load(directory: URL = defaultDirectory) -> Index {
        let file = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: file),
              let plugins = try? JSONDecoder().decode([Entry].self, from: data) else {
            return Index(directory: directory, plugins: [])
        }
        return Index(directory: directory, plugins: plugins)
    }
}

/// Settings that belong to the host, not to one plugin.
enum TerminalPluginSettings {
    static let nodePathKey = "plugin.node.path"
}
