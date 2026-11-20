import AppKit
import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeColdStartTests: XCTestCase {
    private var root: URL!
    private var service: Process?
    private var viewers: [TerminalHostController] = []
    private var windows: [NSWindow] = []
    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/museterm-runtime") }
    private var launch: TerminalRuntimeLaunch {
        .init(executable: "/bin/sh", arguments: ["-c",
            "stty sane echo; printf '__COLD_READY\\n'; while IFS= read -r line; do eval \"$line\"; done"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
    }

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/private/tmp/mucold-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try await startService()
    }

    override func tearDown() {
        for viewer in viewers { viewer.detachRuntimeViewer() }
        for window in windows { window.close() }
        stopService()
        do { try FileManager.default.removeItem(at: root) }
        catch { XCTFail("Could not remove owned cold-start fixture: \(error)") }
        viewers.removeAll(); windows.removeAll()
        super.tearDown()
    }

    func testServiceRestartReopensSavedLocalDirectoryWithoutReplayingStartupCommands() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        attach(original)
        try await wait { original.controller.runtimeHandle?.connected == true }
        let before = try XCTUnwrap(original.runtimeInfo)
        let record = try workspace.runtimeWorkspaceRecord()
        original.controller.detachRuntimeViewer()
        stopService()
        try await startService()

        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let restored = try XCTUnwrap(recovered.selectedTab)
        XCTAssertTrue(restored.runtimeRestoresLocalShell)
        var replayedStartup = false
        attach(restored) { replayedStartup = true }
        try await wait { restored.controller.visibleScreenText().contains("__COLD_READY") }
        let after = try XCTUnwrap(restored.runtimeInfo)
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.generation, before.generation)
        XCTAssertNotEqual(after.pid, before.pid)
        XCTAssertEqual(after.directory, root.path)
        XCTAssertEqual(recovered.projectLayout, workspace.projectLayout)
        XCTAssertFalse(replayedStartup)
        XCTAssertNil(restored.runtimeConnectionIssue)
        XCTAssertTrue(restored.runtimeSessionWasReopened)
        XCTAssertFalse(restored.runtimeRestoreHidden)
        XCTAssertFalse(restored.runtimeRestoresLocalShell, "Recovery permission must not survive a successful attachment")
        restored.runtimeSessionWasReopened = false
        restored.controller.sendProcessInput(bytes: Array("printf '\\n__COLD_%s\\n' INPUT_OK\n".utf8))
        try await wait { restored.controller.visibleScreenText().components(separatedBy: "\n").contains("__COLD_INPUT_OK") }
        XCTAssertFalse(restored.runtimeSessionWasReopened, "Later state frames must not restore a dismissed notice")
        XCTAssertEqual(try recovered.runtimeWorkspaceRecord().snapshot.tabs.first?.runtimeGeneration, after.generation)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testWarmRecoveryKeepsOriginalProcessEvenWhenLocalRestartIsAllowed() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        attach(original)
        try await wait { original.controller.runtimeHandle?.connected == true }
        let before = try XCTUnwrap(original.runtimeInfo)
        let record = try workspace.runtimeWorkspaceRecord()
        original.controller.detachRuntimeViewer()
        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let restored = try XCTUnwrap(recovered.selectedTab)
        var replayedStartup = false
        attach(restored, launch: .init(executable: "/must-not-relaunch", directory: root.path)) { replayedStartup = true }
        try await wait { restored.controller.runtimeHandle?.connected == true }
        XCTAssertEqual(restored.runtimeInfo?.pid, before.pid)
        XCTAssertEqual(restored.runtimeInfo?.generation, before.generation)
        XCTAssertFalse(restored.runtimeSessionWasReopened)
        XCTAssertFalse(replayedStartup)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testLocalRecoveryRejectsExistingSessionWithDifferentGeneration() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        attach(original)
        try await wait { original.controller.runtimeHandle?.connected == true }
        let before = try XCTUnwrap(original.runtimeInfo)
        let record = try workspace.runtimeWorkspaceRecord()
        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let restored = try XCTUnwrap(recovered.selectedTab)
        restored.runtimeGenerationToRestore = UUID()
        attach(restored)
        try await wait { restored.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(restored.controller.runtimeHandle?.lastError?.diagnosticCode, "service_changed")
        XCTAssertFalse(restored.runtimeSessionWasReopened)
        XCTAssertFalse(restored.runtimeRestoreHidden, "A failed pane must not hide healthy siblings")
        XCTAssertEqual(try sessions().first?.pid, before.pid)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testFailureBeforeCreateCanRetryWithoutInventingExistingSession() async throws {
        stopService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, executable: root.appendingPathComponent("missing-helper"))
        try await wait { session.controller.runtimeHandle?.lastErrorStage == "startup" && session.runtimeConnectionIssue == .disconnected }
        XCTAssertFalse(session.runtimeRequiresExisting)
        XCTAssertEqual(try workspace.runtimeWorkspaceRecord().snapshot.tabs.first?.runtimeRequiresExisting, false)
        try await startService()
        session.controller.reconnectRuntime()
        try await wait { session.controller.runtimeHandle?.connected == true }
        XCTAssertTrue(session.runtimeRequiresExisting)
        XCTAssertNil(session.runtimeConnectionIssue)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testMissingAttachOnlySessionReportsEndedAndNeverCreatesShell() async throws {
        let session = TerminalSession(sequence: 1)
        session.runtimeAttachOnly = true
        session.runtimeRequiresExisting = true
        session.runtimeGenerationToRestore = UUID()
        attach(session)
        try await wait { session.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(session.controller.runtimeHandle?.lastError?.diagnosticCode, "session_missing")
        XCTAssertEqual(session.runtimeConnectionIssue, .sessionEnded)
        XCTAssertFalse(session.runtimeRestoreHidden)
        XCTAssertFalse(session.runtimeSessionWasReopened)
        XCTAssertTrue(try sessions().isEmpty)
    }

    func testExitBeforeCreateReplyIsAppliedRecoversPersistedReplacement() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        original.runtimeGenerationToRestore = UUID()
        original.runtimeRequiresExisting = true
        original.runtimeRestoresLocalShell = true
        let oldGeneration = original.runtimeGenerationToRestore
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        lifecycle.attach(workspace)
        let store = TerminalRuntimeWorkspaceStore(root: root)
        attach(original)
        let handle = try XCTUnwrap(original.controller.runtimeHandle)
        let persistIntent = try XCTUnwrap(handle.onCreationRequested)
        var intentWasSavedBeforeCreate = false
        handle.onCreationRequested = { epoch in
            try persistIntent(epoch)
            let saved = try store.load(workspace.runtimeWorkspaceID).snapshot.tabs[0]
            XCTAssertEqual(saved.runtimePendingCreationEpoch, epoch)
            XCTAssertEqual(saved.runtimeGeneration, oldGeneration)
            XCTAssertTrue(try self.sessions().isEmpty)
            intentWasSavedBeforeCreate = true
        }
        // Simulate exit before the creation reply updates the session model.
        handle.onState = { _ in
            do { try lifecycle.prepareForExit() }
            catch { XCTFail("Could not save before fixture exit: \(error)") }
        }
        try await wait { handle.info != nil }
        XCTAssertTrue(intentWasSavedBeforeCreate)
        XCTAssertNil(original.runtimeInfo)
        let replacement = try XCTUnwrap(sessions().first)
        let record = try store.load(workspace.runtimeWorkspaceID)
        XCTAssertNotNil(record.snapshot.tabs[0].runtimePendingCreationEpoch)
        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let restored = try XCTUnwrap(recovered.selectedTab)
        var replayedStartup = false
        attach(restored) { replayedStartup = true }
        try await wait { restored.controller.runtimeHandle?.connected == true }
        XCTAssertEqual(restored.runtimeInfo?.generation, replacement.generation)
        XCTAssertEqual(restored.runtimeInfo?.pid, replacement.pid)
        XCTAssertNil(restored.runtimePendingCreationEpoch)
        XCTAssertFalse(replayedStartup)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testPendingCreationFromAnotherServiceCannotAdoptDifferentGeneration() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        attach(original)
        try await wait { original.controller.runtimeHandle?.connected == true }
        let record = try workspace.runtimeWorkspaceRecord()
        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let restored = try XCTUnwrap(recovered.selectedTab)
        restored.runtimeGenerationToRestore = UUID()
        restored.runtimePendingCreationEpoch = UUID()
        attach(restored)
        try await wait { restored.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(restored.controller.runtimeHandle?.lastError?.diagnosticCode, "service_changed")
        XCTAssertEqual(try sessions().count, 1)
    }

    func testRejectedCreateRemainsEligibleForRetry() async throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        var invalidLaunch = launch
        invalidLaunch.columns = 0
        attach(session, launch: invalidLaunch)
        try await wait { session.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(session.controller.runtimeHandle?.lastError?.diagnosticCode, "invalid_request")
        XCTAssertFalse(session.runtimeRequiresExisting)
        XCTAssertNil(session.runtimePendingCreationEpoch)
        XCTAssertTrue(try sessions().isEmpty)
        session.controller.startRuntime(launch, root: root, executable: helper, ready: {})
        try await wait { session.controller.runtimeHandle?.connected == true }
        XCTAssertNil(session.runtimeConnectionIssue)
        XCTAssertEqual(try sessions().count, 1)
    }

    func testFailedIntentPersistencePreventsCreate() async throws {
        let session = TerminalSession(sequence: 1)
        session.onRuntimeCreationChanged = { throw CocoaError(.fileWriteNoPermission) }
        attach(session)
        try await wait { session.controller.runtimeHandle?.lastError != nil }
        XCTAssertFalse(session.runtimeRequiresExisting)
        XCTAssertNil(session.runtimePendingCreationEpoch)
        XCTAssertTrue(try sessions().isEmpty)
    }

    func testMissingSSHSessionDoesNotOfferUnusableReconnect() async throws {
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(
            SSHConnectionProfile(name: "missing", host: "example.invalid")))
        session.runtimeRequiresExisting = true
        session.runtimeGenerationToRestore = UUID()
        attach(session)
        try await wait { session.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(session.runtimeConnectionIssue, .sessionEnded)
        XCTAssertFalse(session.canManuallyReconnectSSH)
        session.reconnectSSH()
        XCTAssertEqual(session.runtimeConnectionIssue, .sessionEnded)
        XCTAssertTrue(try sessions().isEmpty)
    }

    private func attach(_ session: TerminalSession, launch: TerminalRuntimeLaunch? = nil, executable: URL? = nil,
                        ready: @escaping () -> Void = {}) {
        let controller = session.controller
        let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.container
        controller.layoutTerminalViews()
        windows.append(window); viewers.append(controller)
        controller.startRuntime(launch ?? self.launch, root: root, executable: executable ?? helper, ready: ready)
    }

    private func startService() async throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--root", root.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        service = process
        try await wait {
            guard let connection = try? TerminalRuntimeConnection(root: self.root) else { return false }
            connection.close()
            return true
        }
    }

    private func stopService() {
        if let service, service.isRunning { service.terminate(); service.waitUntilExit() }
        service = nil
    }

    private func sessions() throws -> [TerminalRuntimeSessionInfo] {
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        return try XCTUnwrap(connection.request(.init(action: .list)).sessions)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let states = viewers.map { "\($0.runtimeHandle?.lastError?.diagnosticCode ?? "none")/\($0.runtimeHandle?.lastErrorStage ?? "none")" }
        XCTFail("Private cold-start fixture timed out: \(states)")
        throw TerminalRuntimeConnectionError.timedOut
    }
}
