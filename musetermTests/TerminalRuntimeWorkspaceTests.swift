import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeWorkspaceTests: XCTestCase {
    func testOrdinaryApplicationEnablesPersistentRuntimeByDefault() {
        XCTAssertTrue(TerminalRuntimeService.applicationActivation(arguments: [], environment: [:], bundleID: "im.some.museterm"))
    }

    func testTestHostsKeepPersistentRuntimeExplicitlyOptedIn() {
        XCTAssertFalse(TerminalRuntimeService.applicationActivation(arguments: [], environment: [:], bundleID: "im.some.museterm.goaltests.MuseTerm"))
        XCTAssertFalse(TerminalRuntimeService.applicationActivation(arguments: [],
            environment: ["XCTestConfigurationFilePath": "private-fixture"], bundleID: "im.some.museterm"))
        XCTAssertTrue(TerminalRuntimeService.applicationActivation(arguments: [],
            environment: ["MUSETERM_UI_TEST_RUNTIME": "1", "MUSETERM_AGENT_TEST_TOOL_ROOT": "/private/tmp/private-fixture"],
            bundleID: "im.some.museterm.goaltests.MuseTerm"))
    }

    func testNativeQAActivationRequiresIsolatedBundleAndExplicitRoot() {
        let environment = ["MUSETERM_UI_TEST_RUNTIME": "1", "MUSETERM_AGENT_TEST_TOOL_ROOT": "/private/tmp/qa-tools"]
        XCTAssertTrue(TerminalRuntimeService.testActivation(arguments: [], environment: environment, bundleID: "im.some.museterm.goaltests.MuseTerm"))
        XCTAssertFalse(TerminalRuntimeService.testActivation(arguments: [], environment: environment, bundleID: "im.some.museterm"))
        XCTAssertFalse(TerminalRuntimeService.testActivation(arguments: [], environment: ["MUSETERM_UI_TEST_RUNTIME": "1"], bundleID: "im.some.museterm.goaltests.MuseTerm"))
        XCTAssertFalse(TerminalRuntimeService.testActivation(arguments: [], environment: ["MUSETERM_UI_TEST_RUNTIME": "1", "MUSETERM_AGENT_TEST_TOOL_ROOT": "relative"], bundleID: "im.some.museterm.goaltests.MuseTerm"))
    }
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    private func workspace() -> TerminalWorkspace { TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil) }

    func testNoServiceDiscoveryFallsBackWithoutStartingBackend() async throws {
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let initial = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        XCTAssertTrue(initial.runtimeDiscoveryInProgress)
        XCTAssertTrue(initial.tabs.isEmpty)
        for _ in 0..<200 {
            if !initial.runtimeDiscoveryInProgress { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(initial.runtimeDiscoveryInProgress)
        XCTAssertEqual(initial.tabs.count, 1)
        XCTAssertFalse(initial.tabs[0].runtimeAttachOnly)
        XCTAssertFalse(initial.runtimeRecoveryIssue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.sock").path))
    }

    func testAttachOnlyRecoveryRecordRequiresExistingGeneration() throws {
        let original = workspace()
        var snapshot = try original.runtimeWorkspaceRecord().snapshot
        snapshot.tabs[0].runtimeAttachOnly = true
        let invalid = TerminalRuntimeWorkspaceRecord(workspaceID: original.runtimeWorkspaceID, snapshot: snapshot, detachedIDs: [])
        XCTAssertThrowsError(try invalid.validate())
        snapshot.tabs[0].runtimeGeneration = UUID()
        snapshot.tabs[0].runtimeRequiresExisting = true
        let valid = TerminalRuntimeWorkspaceRecord(workspaceID: original.runtimeWorkspaceID, snapshot: snapshot, detachedIDs: [])
        try TerminalRuntimeWorkspaceStore(root: root).save(valid)
        let loaded = try TerminalRuntimeWorkspaceStore(root: root).load(valid.workspaceID)
        let restored = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: loaded)
        XCTAssertTrue(try XCTUnwrap(restored.selectedTab).runtimeAttachOnly)
        XCTAssertTrue(try XCTUnwrap(restored.selectedTab).runtimeRequiresExisting)
    }

    func testRuntimeRecordPreservesProjectSplitAndTerminalIdentity() throws {
        let original = workspace()
        let first = try XCTUnwrap(original.selectedTab)
        _ = try original.splitTerminal(first.id, axis: .horizontal)
        _ = try original.createProject(name: "review", directory: root.path)
        let record = try original.runtimeWorkspaceRecord()
        let store = TerminalRuntimeWorkspaceStore(root: root)
        try store.save(record)
        let restored = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: try store.load(record.workspaceID))
        XCTAssertEqual(restored.runtimeWorkspaceID, original.runtimeWorkspaceID)
        XCTAssertEqual(restored.tabs.map(\.id), original.tabs.map(\.id))
        XCTAssertEqual(restored.projectLayout, original.projectLayout)
        XCTAssertEqual(restored.selectedID, original.selectedID)
    }

    func testRecoveryRecordPreservesRenderedCursorAndRejectsAnotherGeneration() throws {
        let original = workspace()
        let first = try XCTUnwrap(original.selectedTab)
        let generation = UUID()
        first.runtimeGenerationToRestore = generation
        first.runtimeRenderedCursorToRestore = .init(generation: generation, offset: 123)
        let record = try original.runtimeWorkspaceRecord()
        let store = TerminalRuntimeWorkspaceStore(root: root)
        try store.save(record)
        let restored = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil,
            restoringRuntimeRecord: try store.load(record.workspaceID))
        XCTAssertEqual(restored.selectedTab?.runtimeRenderedCursorToRestore, first.runtimeRenderedCursorToRestore)
        var invalid = record.snapshot
        invalid.tabs[0].runtimeRenderedCursor = .init(generation: UUID(), offset: 123)
        XCTAssertThrowsError(try TerminalRuntimeWorkspaceRecord(workspaceID: record.workspaceID,
            snapshot: invalid, detachedIDs: []).validate())
    }

    func testDetachedTerminalRetainsProjectOwnershipAndOriginalSplit() throws {
        let original = workspace()
        let first = try XCTUnwrap(original.selectedTab)
        let split = try original.splitTerminal(first.id, axis: .vertical)
        let before = original.projectLayout.selectedTab?.layout
        _ = try XCTUnwrap(original.detachTab(split))
        XCTAssertEqual(original.projectLayout.selectedTab?.layout, before)
        XCTAssertNotNil(original.projectLayout.location(of: split.id))
        let record = try original.runtimeWorkspaceRecord()
        XCTAssertEqual(record.detachedIDs, [split.id])
        let restored = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        XCTAssertEqual(restored.pendingRestoredDetachedIDs, [split.id])
        XCTAssertEqual(try restored.runtimeWorkspaceRecord().detachedIDs, [split.id], "Saving before windows mount must retain pending panels")
        XCTAssertEqual(restored.projectLayout, original.projectLayout)
        XCTAssertTrue(original.reattachTab(split))
        XCTAssertEqual(original.projectLayout.selectedTab?.layout, before)
        XCTAssertEqual(original.projectLayout.terminalIDs.count, 2)
    }

    func testClosingProjectAlsoClosesDetachedMember() throws {
        let original = workspace()
        let first = try XCTUnwrap(original.selectedTab)
        let project = try XCTUnwrap(original.projectLayout.selectedProjectID)
        original.newTab()
        _ = original.detachTab(first)
        XCTAssertTrue(original.closeProject(project))
        XCTAssertNil(original.sessionRegistry.sessions[first.id])
        XCTAssertFalse(original.projectLayout.terminalIDs.contains(first.id))
    }

    func testPrivateStoreRejectsSymlinkAndRetainsVictim() throws {
        let original = workspace()
        let record = try original.runtimeWorkspaceRecord()
        let store = TerminalRuntimeWorkspaceStore(root: root)
        try store.save(record)
        let path = store.directory.appendingPathComponent("\(record.workspaceID).json")
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try FileManager.default.removeItem(at: path)
        let victim = root.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
        XCTAssertThrowsError(try store.load(record.workspaceID))
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8))
    }

    func testCorruptRecordIsRetainedAndNotUsedAsNewShellConfiguration() throws {
        let store = TerminalRuntimeWorkspaceStore(root: root)
        let id = UUID()
        let valid = try workspace().runtimeWorkspaceRecord()
        try store.save(valid)
        let corrupt = store.directory.appendingPathComponent("\(id).json")
        try TerminalToolPrivateWriter.write(Data("broken fixture".utf8), to: corrupt)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let first = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        let second = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        XCTAssertNotEqual(first.runtimeWorkspaceID, second.runtimeWorkspaceID)
        XCTAssertTrue(first.runtimeRecoveryIssue || second.runtimeRecoveryIssue)
        try lifecycle.prepareForExit()
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("broken fixture".utf8))
        XCTAssertNotEqual(first.runtimeWorkspaceID, id)
        XCTAssertNotEqual(second.runtimeWorkspaceID, id)
    }

    func testDifferentWindowsClaimDifferentRecordsWithoutDuplicatingTerminals() throws {
        let store = TerminalRuntimeWorkspaceStore(root: root)
        let a = workspace(), b = workspace()
        try store.save(a.runtimeWorkspaceRecord()); try store.save(b.runtimeWorkspaceRecord())
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let recoveredA = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        let recoveredB = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        XCTAssertEqual(Set([recoveredA.runtimeWorkspaceID, recoveredB.runtimeWorkspaceID]), Set([a.runtimeWorkspaceID, b.runtimeWorkspaceID]))
        XCTAssertTrue(Set(recoveredA.tabs.map(\.id)).isDisjoint(with: recoveredB.tabs.map(\.id)))
    }

    func testExplicitlyClosedLastTerminalRemovesRecoveryRecord() throws {
        let original = workspace()
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        lifecycle.attach(original)
        try lifecycle.prepareForExit()
        XCTAssertEqual(try TerminalRuntimeWorkspaceStore(root: root).recordIDs(), [original.runtimeWorkspaceID])
        XCTAssertTrue(original.closeSelectedTab())
        XCTAssertTrue(try TerminalRuntimeWorkspaceStore(root: root).recordIDs().isEmpty)
    }

    func testDuplicateTerminalIdentityIsRejectedBeforeRestore() throws {
        let original = workspace()
        var snapshot = try original.runtimeWorkspaceRecord().snapshot
        snapshot.tabs.append(snapshot.tabs[0])
        let record = TerminalRuntimeWorkspaceRecord(workspaceID: UUID(), snapshot: snapshot, detachedIDs: [])
        XCTAssertThrowsError(try record.validate())
        let restored = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        XCTAssertTrue(restored.runtimeRecoveryIssue)
        XCTAssertNotEqual(restored.tabs.first?.id, snapshot.tabs.first?.terminalID)
        XCTAssertNotEqual(restored.runtimeWorkspaceID, record.workspaceID)
    }

    func testRecoveryRecordOmitsEnvironmentStartupCommandsAndSSHOptions() throws {
        let original = workspace()
        let profile = TerminalProfile(name: "fixture", customPrompt: "fixture-sensitive-prompt",
            environment: ["FIXTURE_TOKEN": "fixture-sensitive-environment"], startupCommands: ["fixture-sensitive-startup"])
        _ = original.newTab(profile: profile)
        _ = original.openSSH(profile: SSHConnectionProfile(name: "fixture-ssh", host: "example.invalid",
            extraOptions: ["ProxyCommand fixture-sensitive-proxy"], startupCommands: ["fixture-sensitive-ssh-startup"]))
        let record = try original.runtimeWorkspaceRecord()
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-sensitive"))
        try record.validate()
    }
}
