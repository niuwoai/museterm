import Foundation

nonisolated enum TerminalProjectImportSource: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, willdeep, qoder, workbuddy, dsh
    var id: String { rawValue }
    @MainActor var name: String { L10n.string("project.import.source.\(rawValue)") }
}

nonisolated struct TerminalProjectImportCandidate: Identifiable, Sendable {
    var id: String { directory }
    let directory: String
    var name: String
    var sources: Set<TerminalProjectImportSource>
}

nonisolated struct TerminalProjectImportResult: Sendable {
    var candidates: [TerminalProjectImportCandidate] = []
    var skippedRecords = 0
    var truncated = false
}

/// Reads local directory metadata only. Nothing is executed or written to a provider's store.
nonisolated struct TerminalProjectImportScanner {
    private static let documentLimit = 8 * 1_024 * 1_024
    private static let headerLimit = 128 * 1_024
    private static let entryLimit = 4_000
    let home: URL
    var environment: [String: String] = [:]
    private var records: [String: TerminalProjectImportCandidate] = [:]
    private var result = TerminalProjectImportResult()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    static func canonicalDirectory(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.unicodeScalars.contains(where: { $0.value < 32 }),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    mutating func scan() -> TerminalProjectImportResult {
        readClaude()
        readCodex()
        readWillDeep()
        readProjectHeaders(root: providerRoot("QODER_CONFIG_DIR", fallback: ".qoder").appendingPathComponent("projects"), source: .qoder)
        readProjectHeaders(root: home.appendingPathComponent(".workbuddy/projects"), source: .workbuddy)
        readDSH()
        result.candidates = records.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedSame
                ? $0.directory < $1.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return result
    }

    private func providerRoot(_ variable: String, fallback: String) -> URL {
        if let custom = environment[variable], custom.hasPrefix("/") { return URL(fileURLWithPath: custom) }
        return home.appendingPathComponent(fallback)
    }

    private mutating func add(_ value: Any?, name: String? = nil, source: TerminalProjectImportSource) {
        guard let path = value as? String, let canonical = Self.canonicalDirectory(path) else { return }
        if var existing = records[canonical] {
            existing.sources.insert(source); records[canonical] = existing
        } else {
            let proposed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = proposed.flatMap { !$0.isEmpty && $0.count <= 120 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) ? $0 : nil }
            records[canonical] = .init(directory: canonical,
                name: title ?? URL(fileURLWithPath: canonical).lastPathComponent, sources: [source])
        }
    }

    private mutating func document(_ url: URL) -> Any? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.documentLimit else {
                result.skippedRecords += 1; return nil
            }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch { result.skippedRecords += 1; return nil }
    }

    private mutating func files(_ root: URL, recursive: Bool = false) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var entries: [URL] = []
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }) else { result.skippedRecords += 1; return [] }
        var visited = 0
        while let url = iterator.nextObject() as? URL {
            visited += 1
            if visited > Self.entryLimit { result.truncated = true; break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values?.isDirectory == true {
                if !recursive || ["node_modules", "subagents", "logs", "cache", "blobs"].contains(url.lastPathComponent)
                    || iterator.level > 8 { iterator.skipDescendants() }
            } else { entries.append(url) }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private mutating func readClaude() {
        let config = document(home.appendingPathComponent(".claude.json")) as? [String: Any]
        for path in (config?["projects"] as? [String: Any] ?? [:]).keys { add(path, source: .claude) }
        readProjectHeaders(root: providerRoot("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("projects"), source: .claude)
    }

    private mutating func readCodex() {
        let root = providerRoot("CODEX_HOME", fallback: ".codex")
        if let state = document(root.appendingPathComponent(".codex-global-state.json")) as? [String: Any] {
            for key in ["electron-saved-workspace-roots", "active-workspace-roots"] {
                for path in state[key] as? [String] ?? [] { add(path, source: .codex) }
            }
            for project in (state["local-projects"] as? [String: [String: Any]] ?? [:]).values {
                for path in project["rootPaths"] as? [String] ?? [] { add(path, name: project["name"] as? String, source: .codex) }
            }
        }
        for file in files(root.appendingPathComponent("sessions"), recursive: true) where file.pathExtension == "jsonl" {
            readHeader(file, source: .codex)
        }
    }

    private mutating func readWillDeep() {
        let projects = document(home.appendingPathComponent("Library/Application Support/WillDeep/projects.json")) as? [[String: Any]] ?? []
        for project in projects {
            for path in project["folderPaths"] as? [String] ?? [] {
                add(path, name: project["displayName"] as? String, source: .willdeep)
            }
        }
        for file in files(home.appendingPathComponent(".willdeep/sessions")) where file.pathExtension == "json" {
            if let session = document(file) as? [String: Any] { add(session["workspace"], source: .willdeep) }
        }
    }

    private mutating func readProjectHeaders(root: URL, source: TerminalProjectImportSource) {
        for file in files(root, recursive: true) {
            if file.lastPathComponent.hasSuffix(".meta.json"), let meta = document(file) as? [String: Any] {
                add(meta["cwd"], source: source)
            } else if file.pathExtension == "jsonl" { readHeader(file, source: source) }
        }
    }

    private mutating func readHeader(_ file: URL, source: TerminalProjectImportSource) {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.headerLimit) ?? Data()
            var sawValidRow = false
            for line in data.split(separator: 10).prefix(32) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                sawValidRow = true
                if source == .codex {
                    guard row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any] else { continue }
                    add(payload["cwd"], source: source); return
                }
                if let cwd = row["cwd"] as? String { add(cwd, source: source); return }
            }
            if !sawValidRow && !data.isEmpty { result.skippedRecords += 1 }
        } catch { result.skippedRecords += 1 }
    }

    private mutating func readDSH() {
        let root = providerRoot("DSH_HOME", fallback: ".dsh")
        for file in files(root, recursive: true) where file.pathExtension == "json" {
            guard file.lastPathComponent == "workspace.json" || file.deletingLastPathComponent().lastPathComponent == "workspaces" else { continue }
            guard let doc = document(file) as? [String: Any] else { continue }
            if let unit = doc["unit"] as? [String: Any], unit["name"] as? String == "workspace",
               let tables = doc["tables"] as? [String: Any], let workspaces = tables["workspaces"] as? [String: [String: Any]] {
                for record in workspaces.values { add(record["path"], name: record["title"] as? String, source: .dsh) }
            } else if let value = doc["record"] as? [String: Any], doc["version"] as? Int == 2 {
                add(value["path"], name: value["title"] as? String, source: .dsh)
            }
        }
    }
}
