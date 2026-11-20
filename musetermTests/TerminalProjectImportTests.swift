import XCTest
@testable import museterm

@MainActor
final class TerminalProjectImportTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-import-\(UUID())")
        project = root.appendingPathComponent("代码 with-hyphens")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ value: Any, jsonl: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: value)
        if jsonl { data.append(10) }
        try data.write(to: url)
    }

    private func scan(environment: [String: String] = [:]) -> TerminalProjectImportResult {
        var scanner = TerminalProjectImportScanner(home: root, environment: environment)
        return scanner.scan()
    }

    func testSixProvidersMergeOneCanonicalDirectory() throws {
        try write(".claude.json", ["projects": [project.path: [:]]])
        try write(".codex/.codex-global-state.json", ["electron-saved-workspace-roots": [project.path]])
        try write("Library/Application Support/WillDeep/projects.json", [["displayName": "Code", "folderPaths": [project.path]]])
        try write(".qoder/projects/not-a-path/session.jsonl", ["cwd": project.path], jsonl: true)
        try write(".workbuddy/projects/not-a-path/session.meta.json", ["cwd": project.path])
        try write(".dsh/data/workspace/workspaces/one.json", ["version": 2, "record": ["path": project.path, "title": "Code"]])
        let value = scan()
        XCTAssertEqual(value.candidates.count, 1)
        XCTAssertEqual(value.candidates.first?.sources, Set(TerminalProjectImportSource.allCases))
        XCTAssertEqual(value.skippedRecords, 0)
    }

    func testJSONLMetadataDoesNotDecodeSlugOrImportPathsFromMessages() throws {
        try write(".claude/projects/ambiguous-slug/session.jsonl", ["cwd": project.path], jsonl: true)
        try write(".codex/sessions/2026/10/one.jsonl", ["type": "session_meta", "payload": ["cwd": project.path]], jsonl: true)
        try write(".codex/sessions/2026/10/two.jsonl", ["type": "response_item", "payload": ["cwd": root.path]], jsonl: true)
        let value = scan()
        XCTAssertEqual(value.candidates.count, 1)
        XCTAssertEqual(value.candidates[0].sources, [.claude, .codex])
    }

    func testWillDeepSessionAndLegacyDSHUnit() throws {
        try write(".willdeep/sessions/one.json", ["workspace": project.path])
        try write(".dsh/data/workspace.json", ["unit": ["name": "workspace", "version": 2],
            "tables": ["workspaces": ["one": ["path": project.path, "title": "Code"]]]])
        XCTAssertEqual(scan().candidates.first?.sources, [.willdeep, .dsh])
    }

    func testSymlinkAndTrailingSlashDeduplicateWithoutMergingSiblingDirectories() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let sibling = root.appendingPathComponent("other/代码 with-hyphens")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try write(".codex/.codex-global-state.json", ["electron-saved-workspace-roots": [project.path + "/", alias.path, sibling.path]])
        XCTAssertEqual(scan().candidates.count, 2)
    }

    func testInvalidRelativeMissingAndFilePathsAreExcluded() throws {
        let file = root.appendingPathComponent("plain-file")
        try Data().write(to: file)
        try write(".claude.json", ["projects": ["relative": [:], "/museterm-missing-\(UUID())": [:], file.path: [:]]])
        XCTAssertTrue(scan().candidates.isEmpty)
        XCTAssertNil(TerminalProjectImportScanner.canonicalDirectory(project.path + "\n"))
    }

    func testMalformedStoreDoesNotHideOtherProviders() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: root.appendingPathComponent(".codex/.codex-global-state.json"))
        try write(".willdeep/sessions/one.json", ["workspace": project.path])
        let value = scan()
        XCTAssertEqual(value.skippedRecords, 1)
        XCTAssertEqual(value.candidates.first?.sources, [.willdeep])
    }

    func testProviderRootOverrideAndSkippingSymlinkedHistory() throws {
        try write("custom/projects/one/one.jsonl", ["cwd": project.path], jsonl: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".qoder"), withDestinationURL: root.appendingPathComponent("custom"))
        XCTAssertEqual(scan(environment: ["QODER_CONFIG_DIR": root.appendingPathComponent("custom").path]).candidates.count, 1)
    }

    func testImportPreservesFocusAndProcessesAndIsIdempotent() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let selected = workspace.selectedID
        let terminals = workspace.tabs.map(\.id)
        let layoutSelection = workspace.projectLayout.selectedProjectID
        let candidate = TerminalProjectImportCandidate(directory: project.path, name: "Code", sources: [.codex])
        XCTAssertEqual(try workspace.importProjects([candidate, candidate]), 1)
        XCTAssertEqual(workspace.tabs.map(\.id), terminals)
        XCTAssertEqual(workspace.selectedID, selected)
        XCTAssertEqual(workspace.projectLayout.selectedProjectID, layoutSelection)
        XCTAssertEqual(try workspace.importProjects([candidate]), 0)
        let restored = try JSONDecoder().decode(TerminalProjectLayout.self, from: JSONEncoder().encode(workspace.projectLayout))
        XCTAssertEqual(restored.projects.last?.directory, project.resolvingSymlinksInPath().path)
        XCTAssertTrue(restored.projects.last?.tabs.isEmpty == true)
    }

    func testImportRejectsInvalidNameAtomically() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let before = workspace.projectLayout
        XCTAssertThrowsError(try workspace.importProjects([.init(directory: project.path, name: "", sources: [])]))
        XCTAssertEqual(workspace.projectLayout, before)
    }
}
