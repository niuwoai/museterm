import Foundation

/// Keep live legacy sockets and existing data in place; new installations use MuseTerm.
nonisolated enum MuseTermLegacyCompatibility {
    static let legacyClientID = "qterm-cli"

    static func directory(_ component: String, base: URL? = nil) -> URL {
        let base = base ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        let legacy = base.appendingPathComponent("QTerm", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }
}
