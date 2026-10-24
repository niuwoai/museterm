import Foundation

struct TerminalQuickPathRecord: Codable, Equatable, Identifiable {
    private static let contextualLeafNames: Set<String> = [
        "desktop",
        "documents",
        "downloads",
        "library"
    ]

    var path: String
    var lastVisitedAt: Date
    var visitCount: Int

    var id: String { path }

    var displayName: String {
        let components = Self.displayPathComponents(for: path)
        guard let leaf = components.last else { return path }
        guard Self.contextualLeafNames.contains(leaf.lowercased()), components.count >= 2 else {
            return leaf
        }
        return "\(components[components.count - 2]) / \(leaf)"
    }

    var normalized: TerminalQuickPathRecord {
        TerminalQuickPathRecord(
            path: path,
            lastVisitedAt: lastVisitedAt,
            visitCount: max(1, visitCount)
        )
    }

    private static func displayPathComponents(for path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return (standardized as NSString).pathComponents
            .filter { component in
                component != "/" && !component.isEmpty
            }
    }
}

enum TerminalQuickPathStore {
    private static let maxStoredPaths = 80
    static let minimumFrequentVisitCount = 5
    private static let fileName = "local-paths.json"
    private static let saveQueue = DispatchQueue(label: "im.some.museterm.quick-paths.save", qos: .utility)
    private static var directoryOverride: URL?

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        #if DEBUG
        if TerminalToolPaths.isIsolatedTesting {
            return TerminalToolPaths.rootDirectory.appendingPathComponent("QuickPaths", isDirectory: true)
        }
        #endif
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return base
                .appendingPathComponent("MuseTerm", isDirectory: true)
                .appendingPathComponent("QuickPaths", isDirectory: true)
        } catch {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("MuseTerm", isDirectory: true)
                .appendingPathComponent("QuickPaths", isDirectory: true)
        }
    }

    static func load() -> [TerminalQuickPathRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: fileURL)
            return prepared(try decoder.decode([TerminalQuickPathRecord].self, from: data), validateExistingDirectories: true)
        } catch {
            NSLog("MuseTerm quick path load failed: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ records: [TerminalQuickPathRecord]) {
        write(prepared(records), directory: directory, fileURL: fileURL)
    }

    static func saveAsync(_ records: [TerminalQuickPathRecord]) {
        let prepared = prepared(records)
        let targetDirectory = directory
        let targetFileURL = targetDirectory.appendingPathComponent(fileName)
        saveQueue.async {
            write(prepared, directory: targetDirectory, fileURL: targetFileURL)
        }
    }

    private static func write(_ records: [TerminalQuickPathRecord], directory: URL, fileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MuseTerm quick path save failed: \(error.localizedDescription)")
        }
    }

    static func record(
        directory rawDirectory: String?,
        in records: [TerminalQuickPathRecord],
        now: Date = Date()
    ) -> [TerminalQuickPathRecord] {
        guard let path = TerminalWorkingDirectory.normalizedExistingDirectory(rawDirectory) else {
            return prepared(records)
        }

        var updated = prepared(records)
        if let index = updated.firstIndex(where: { $0.path == path }) {
            updated[index].lastVisitedAt = now
            updated[index].visitCount = max(1, updated[index].visitCount) + 1
        } else {
            updated.append(TerminalQuickPathRecord(path: path, lastVisitedAt: now, visitCount: 1))
        }
        return prepared(updated)
    }

    static func recent(_ records: [TerminalQuickPathRecord], limit: Int) -> [TerminalQuickPathRecord] {
        prepared(records)
            .sorted {
                if $0.lastVisitedAt != $1.lastVisitedAt {
                    return $0.lastVisitedAt > $1.lastVisitedAt
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    static func frequent(
        _ records: [TerminalQuickPathRecord],
        limit: Int,
        excludingPaths: Set<String> = []
    ) -> [TerminalQuickPathRecord] {
        prepared(records)
            .filter { record in
                record.visitCount >= minimumFrequentVisitCount && !excludingPaths.contains(record.path)
            }
            .sorted {
                if $0.visitCount != $1.visitCount {
                    return $0.visitCount > $1.visitCount
                }
                if $0.lastVisitedAt != $1.lastVisitedAt {
                    return $0.lastVisitedAt > $1.lastVisitedAt
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        return previous
    }

    static var blacklistFileURL: URL {
        directory.appendingPathComponent("blacklisted-paths.json")
    }

    private static func prepared(
        _ records: [TerminalQuickPathRecord],
        validateExistingDirectories: Bool = false
    ) -> [TerminalQuickPathRecord] {
        var seen = Set<String>()
        return records
            .compactMap { record -> TerminalQuickPathRecord? in
                let path: String
                if validateExistingDirectories {
                    guard let existingPath = TerminalWorkingDirectory.normalizedExistingDirectory(record.path) else {
                        return nil
                    }
                    path = existingPath
                } else {
                    let trimmed = record.path.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    path = (trimmed as NSString).expandingTildeInPath
                }

                guard seen.insert(path).inserted else {
                    return nil
                }
                return TerminalQuickPathRecord(
                    path: path,
                    lastVisitedAt: record.lastVisitedAt,
                    visitCount: max(1, record.visitCount)
                )
            }
            .sorted {
                if $0.lastVisitedAt != $1.lastVisitedAt {
                    return $0.lastVisitedAt > $1.lastVisitedAt
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(maxStoredPaths)
            .map { $0.normalized }
    }
}

/// 被「拉黑」的路径：无论访问多频繁，都不再出现在最近/常用路径里。存于快捷路径同目录，
/// 复用 TerminalQuickPathStore 的测试目录注入。存归一化（展开 ~）后的绝对路径字符串。
enum TerminalQuickPathBlacklistStore {
    static func load() -> Set<String> {
        let url = TerminalQuickPathStore.blacklistFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let list = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
            return Set(list.map { ($0 as NSString).expandingTildeInPath })
        } catch {
            NSLog("MuseTerm quick path blacklist load failed: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ paths: Set<String>) {
        let url = TerminalQuickPathStore.blacklistFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(paths.sorted()).write(to: url, options: .atomic)
        } catch {
            NSLog("MuseTerm quick path blacklist save failed: \(error.localizedDescription)")
        }
    }
}
