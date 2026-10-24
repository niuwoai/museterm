import XCTest
@testable import museterm

@MainActor
final class TerminalProjectLayoutTests: XCTestCase {
    func testSplittingLocalTerminalInheritsOSC7DirectoryWithHostname() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qterm cwd \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var uri = URLComponents()
        uri.scheme = "file"; uri.host = "fixture.local"; uri.path = directory.path
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        original.currentDirectory = try XCTUnwrap(uri.string)
        let split = try workspace.splitTerminal(original.id, axis: .vertical)
        XCTAssertEqual(split.launchConfiguration.localStartDirectory, directory.path)
        XCTAssertEqual(split.currentDirectory, directory.path)
    }
    func testSplitMoveAndClosePreserveTerminalIdentityAndCollapseTree() throws {
        let first = UUID(), second = UUID(), third = UUID()
        var state = TerminalProjectLayout()
        let project = try state.addProject(name: "api", directory: "/tmp/api", terminal: first)
        try state.split(terminal: first, adding: second, axis: .horizontal)
        try state.split(terminal: second, adding: third, axis: .vertical)
        XCTAssertEqual(state.terminalIDs, [first, second, third])
        XCTAssertEqual(state.focusedTerminalID, third)
        let destination = try state.addProject(name: "review", directory: "/tmp/api")
        try state.move(terminal: second, to: destination)
        XCTAssertEqual(Set(state.terminalIDs), Set([first, second, third]))
        XCTAssertEqual(state.selectedProjectID, destination)
        XCTAssertEqual(state.focusedTerminalID, second)
        try state.select(terminal: third)
        XCTAssertEqual(state.selectedProjectID, project)
        try state.remove(terminal: first)
        XCTAssertEqual(state.selectedTab?.layout, .terminal(third))
        try state.remove(terminal: third)
        XCTAssertNil(state.selectedTab)
        try state.validate()
    }

    func testFocusRestoresIndependentlyForEachProjectAndTab() throws {
        var state = TerminalProjectLayout()
        let first = UUID(), second = UUID(), third = UUID()
        let a = try state.addProject(name: "a", terminal: first)
        try state.addTab(terminal: second, projectID: a)
        let b = try state.addProject(name: "b", terminal: third)
        try state.select(terminal: second)
        try state.select(terminal: third)
        XCTAssertEqual(state.selectedProjectID, b)
        state.selectedProjectID = a
        XCTAssertEqual(state.focusedTerminalID, second)
        try state.validate()
    }

    func testInvalidMovesAndDuplicateLeavesDoNotMutateLayout() throws {
        var state = TerminalProjectLayout()
        let terminal = UUID()
        _ = try state.addProject(name: "a", terminal: terminal)
        let before = state
        XCTAssertThrowsError(try state.split(terminal: terminal, adding: terminal, axis: .horizontal))
        XCTAssertThrowsError(try state.move(terminal: terminal, to: UUID()))
        XCTAssertThrowsError(try state.addProject(name: " "))
        XCTAssertEqual(state, before)
    }

    func testSnapshotRoundTripAndCorruptDuplicateLeafRejection() throws {
        var state = TerminalProjectLayout()
        let first = UUID(), second = UUID()
        _ = try state.addProject(name: "project", terminal: first)
        try state.split(terminal: first, adding: second, axis: .horizontal)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(TerminalProjectLayout.self, from: data)
        try restored.validate()
        XCTAssertEqual(restored, state)
        state.projects[0].tabs.append(state.projects[0].tabs[0])
        XCTAssertThrowsError(try state.validate())
    }

    func testResizeKeepsSplitAndTerminalIDsAndClampsRatio() throws {
        var state = TerminalProjectLayout()
        let first = UUID(), second = UUID()
        _ = try state.addProject(name: "project", terminal: first)
        try state.split(terminal: first, adding: second, axis: .horizontal)
        let split = try XCTUnwrap(state.selectedTab?.layout.splitIDs.first)
        try state.resize(splitID: split, ratio: 0.999)
        guard case .split(let id, _, let ratio, _, _) = state.selectedTab?.layout else { return XCTFail("missing split") }
        XCTAssertEqual(id, split)
        XCTAssertEqual(ratio, 0.9)
        XCTAssertEqual(state.terminalIDs, [first, second])
        XCTAssertThrowsError(try state.resize(splitID: split, ratio: .nan))
        try state.validate()
    }

    func testDeletingProjectReturnsAllLeavesAndSelectsAnotherProject() throws {
        var state = TerminalProjectLayout()
        let first = UUID(), second = UUID()
        _ = try state.addProject(name: "a", terminal: first)
        let b = try state.addProject(name: "b", terminal: second)
        XCTAssertEqual(try state.removeProject(b), [second])
        XCTAssertEqual(state.focusedTerminalID, first)
        try state.validate()
    }

    func testLegacySnapshotRestoresTabsAndSelectedTerminalWithoutInventingSplits() throws {
        let snapshot = TerminalWorkspaceSnapshot(selectedIndex: 1, tabs: [.local(directory: "/tmp/a"), .local(directory: "/tmp/b")])
        let restored = try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let first = UUID(), second = UUID()
        let layout = try restored.restoredProjectLayout(terminalIDs: [first, second], defaultName: "Project")
        XCTAssertEqual(layout.projects.count, 1)
        XCTAssertEqual(layout.selectedProject?.tabs.count, 2)
        XCTAssertEqual(layout.focusedTerminalID, second)
        XCTAssertTrue(layout.selectedTab?.layout.splitIDs.isEmpty == true)
    }

    func testNewSnapshotRestoresSameLiveIDsAndCanExplicitlyRemapRecreatedTerminals() throws {
        let first = UUID(), second = UUID()
        var layout = TerminalProjectLayout()
        _ = try layout.addProject(name: "Project", terminal: first)
        try layout.split(terminal: first, adding: second, axis: .vertical)
        var tabs = [TerminalWorkspaceSnapshot.Tab.local(directory: "/tmp/a"), .local(directory: "/tmp/b")]
        tabs[0].terminalID = first; tabs[1].terminalID = second
        let snapshot = TerminalWorkspaceSnapshot(selectedIndex: 1, tabs: tabs, projectLayout: layout)
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(try snapshot.restoredProjectLayout(terminalIDs: [first, second], defaultName: "Unused"), layout)
        let new = [UUID(), UUID()]
        let recreated = try snapshot.restoredProjectLayout(terminalIDs: new, defaultName: "Unused")
        XCTAssertEqual(recreated.terminalIDs, new)
        XCTAssertEqual(recreated.selectedProjectID, layout.selectedProjectID)
        XCTAssertEqual(recreated.focusedTerminalID, new[1])
        XCTAssertEqual(recreated.selectedTab?.layout.splitIDs, layout.selectedTab?.layout.splitIDs)
    }

    func testSnapshotRejectsUnknownSchemaMissingOrDuplicateTerminalMapping() throws {
        var snapshot = TerminalWorkspaceSnapshot(selectedIndex: 0, tabs: [.local(directory: "/tmp")])
        snapshot.schemaVersion = 99
        XCTAssertThrowsError(try snapshot.restoredProjectLayout(terminalIDs: [UUID()], defaultName: "P"))
        snapshot.schemaVersion = 1
        XCTAssertThrowsError(try snapshot.restoredProjectLayout(terminalIDs: [], defaultName: "P"))
        var layout = TerminalProjectLayout()
        _ = try layout.addProject(name: "P", terminal: UUID())
        snapshot.projectLayout = layout
        XCTAssertThrowsError(try snapshot.restoredProjectLayout(terminalIDs: [UUID()], defaultName: "P"))
    }
}
