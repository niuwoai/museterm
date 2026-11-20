import Foundation

enum TerminalToolResponseRetention {
    static let lifetime: TimeInterval = 300
    static let maximumFiles = 512

    static func prune(directory: URL, now: Date = Date()) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
        for (index, entry) in files.enumerated() {
            // Never evict a response still inside a normal client's receive window.
            if now.timeIntervalSince(entry.1) > lifetime || (files.count - index > maximumFiles && now.timeIntervalSince(entry.1) > 10) {
                try manager.removeItem(at: entry.0)
            }
        }
    }
}
