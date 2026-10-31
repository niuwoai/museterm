import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeViewTests: XCTestCase {
    func testReconnectPolicyBoundsRetriesAndRejectsIdentityChanges() {
        var policy = TerminalRuntimeReconnectPolicy()
        XCTAssertEqual(policy.nextDelay(for: TerminalRuntimeConnectionError.timedOut, healthyFor: 0), 0.25)
        XCTAssertEqual(policy.nextDelay(for: TerminalRuntimeConnectionError.unavailable, healthyFor: 1), 1)
        XCTAssertEqual(policy.nextDelay(for: TerminalRuntimeConnectionError.timedOut, healthyFor: 2), 3)
        XCTAssertNil(policy.nextDelay(for: TerminalRuntimeConnectionError.unavailable, healthyFor: 0))
        XCTAssertEqual(policy.nextDelay(for: TerminalRuntimeConnectionError.timedOut, healthyFor: 30), 0.25)
        for error in [TerminalRuntimeConnectionError.serviceChanged, .invalidCapability, .invalidResponse,
                      .incompatibleProtocol, .cancelled, .frameTooLarge, .rejected("control_changed")] {
            XCTAssertNil(policy.nextDelay(for: error, healthyFor: 60))
        }
    }

    func testReconnectTrimsLateAcknowledgedOutputAndHistoricalPrefix() {
        let generation = UUID()
        var response = TerminalRuntimeResponse(serviceEpoch: UUID(), id: UUID(), action: .subscribe)
        response.cursor = .init(generation: generation, offset: 110)
        response.data = Data("0123456789".utf8)
        for (offset, expected, historical) in [(90, "0123456789", 7), (105, "56789", 2), (120, "", 0)] {
            let (trimmed, remainingHistory) = TerminalRuntimeReplayBoundary.removingRenderedOverlap(
                from: response, renderedThrough: .init(generation: generation, offset: UInt64(offset)), historicalBytes: 7)
            XCTAssertEqual(trimmed.data, Data(expected.utf8))
            XCTAssertEqual(remainingHistory, historical)
            XCTAssertEqual(trimmed.cursor, response.cursor)
        }
        let (unchanged, _) = TerminalRuntimeReplayBoundary.removingRenderedOverlap(
            from: response, renderedThrough: .init(generation: UUID(), offset: 110), historicalBytes: 7)
        XCTAssertEqual(unchanged.data, response.data)
    }

    func testDetachCancelsScheduledSubscriptionRetry() async throws {
        let (root, helper) = try await startService()
        let handle = TerminalRuntimeSessionHandle(id: UUID(), root: root, executable: helper)
        defer { handle.detach() }
        var recoveries = 0
        var failures = 0
        var outputs = 0
        handle.onOutput = { _, _, complete in outputs += 1; complete() }
        handle.onFailure = { _ in failures += 1 }
        handle.onRecovering = { [weak handle] in recoveries += 1; handle?.detach() }
        handle.start(.init(executable: "/bin/sh", arguments: ["-c", "sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path))
        try await waitUntil { handle.connected }
        handle.interruptSubscriptionForTesting()
        try await waitUntil { recoveries == 1 }
        let previousOutputs = outputs
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(outputs, previousOutputs)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(failures, 0)
    }

    func testSubscriptionAutomaticallyReconnectsWithoutDuplicatingOutputOrReplacingPTY() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "printf '__RECONNECT_ONCE__'; sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil { session.controller.visibleScreenText().contains("__RECONNECT_ONCE__") }
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        let original = try XCTUnwrap(handle.info)
        var recoveries = 0
        let recovering = handle.onRecovering
        handle.onRecovering = { recoveries += 1; recovering?() }
        handle.interruptSubscriptionForTesting()
        try await waitUntil("automatic reconnect") { recoveries == 1 && handle.connected }
        XCTAssertEqual(handle.info?.pid, original.pid)
        XCTAssertEqual(handle.info?.generation, original.generation)
        XCTAssertNil(session.runtimeConnectionIssue)
        XCTAssertNil(handle.lastError)
        XCTAssertEqual(session.controller.visibleScreenText().components(separatedBy: "__RECONNECT_ONCE__").count, 2)
    }

    func testRepeatedSubscriptionFailuresExhaustBudgetThenManualReconnectRecoversSamePTY() async throws {
        let (root, helper) = try await startService()
        let handle = TerminalRuntimeSessionHandle(id: UUID(), root: root, executable: helper)
        defer { handle.detach() }
        var recoveries = 0
        var failures = 0
        var breakTransport = true
        handle.onRecovering = { recoveries += 1 }
        handle.onFailure = { _ in failures += 1 }
        handle.onOutput = { [weak handle] _, _, completion in
            completion()
            if breakTransport { handle?.interruptSubscriptionForTesting() }
        }
        handle.start(.init(executable: "/bin/sh", arguments: ["-c", "sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path))
        try await waitUntil("retry budget exhausted") { failures == 1 }
        let original = try XCTUnwrap(handle.info)
        XCTAssertEqual(recoveries, 3)
        XCTAssertFalse(handle.connected)
        XCTAssertFalse(handle.reconnecting)
        breakTransport = false
        handle.reconnect()
        try await waitUntil("manual recovery") { handle.connected }
        // A second press while the replacement is healthy must not be swallowed:
        // the old reader is still unwinding when it arrives.
        handle.reconnect()
        try await waitUntil("second manual recovery") { handle.connected }
        XCTAssertEqual(handle.info?.pid, original.pid)
        XCTAssertEqual(handle.info?.generation, original.generation)
        XCTAssertEqual(failures, 1)
    }

    func testSlowConsumerAcknowledgementKeepsSubscriptionAndReconnectRestartsIt() async throws {
        let previousDeadline = TerminalRuntimeLimits.consumerAcknowledgementDeadlineOverride
        TerminalRuntimeLimits.consumerAcknowledgementDeadlineOverride = 1
        defer { TerminalRuntimeLimits.consumerAcknowledgementDeadlineOverride = previousDeadline }
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        // One byte a second stays under the helper's output cap while keeping the
        // subscription busy, so the only way the banner appears is the app timing
        // its own parse out.
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "while true; do printf x; sleep 1; done"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("slow output started") { session.controller.visibleScreenText().contains("x") }
        let view = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        view.holdExternalFeedCompletionForTesting = true
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        let original = try XCTUnwrap(handle.info)
        try await waitUntil("consumer acknowledgement overdue") { handle.reconnecting }
        XCTAssertNil(session.runtimeConnectionIssue, "A slow parse is not a dead backend")
        XCTAssertEqual(handle.info?.pid, original.pid)
        view.holdExternalFeedCompletionForTesting = false
        try await waitUntil("subscription resumed after the parse") { handle.connected && !handle.reconnecting }

        view.holdExternalFeedCompletionForTesting = true
        try await waitUntil("consumer acknowledgement overdue again") { handle.reconnecting }
        session.controller.reconnectRuntime()
        XCTAssertNil(session.runtimeConnectionIssue, "Pressing reconnect must not leave the banner up")
        view.holdExternalFeedCompletionForTesting = false
        try await waitUntil("manual reconnect delivered fresh output") {
            handle.connected && !handle.reconnecting && session.runtimeConnectionIssue == nil
        }
        XCTAssertEqual(handle.info?.pid, original.pid)
        XCTAssertEqual(handle.info?.generation, original.generation)
    }

    func testAICommandFillReachesRuntimeBackedTerminal() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("fill fixture shell ready") {
            session.controller.runtimeHandle?.connected == true && session.controller.visibleScreenText().contains("__MODE_READY")
        }
        let model = AICommandAssistantModel()
        model.present(for: session)
        model.stageReviewedCandidateForTesting(AICommandSuggestion(
            command: "printf '__AI_FILLED__'", explanation: "fixture"))
        model.fillSelectedCommand(in: workspace)
        try await waitUntil("filled command reached the PTY") {
            session.controller.visibleScreenText().contains("__AI_FILLED__") && session.aiLease == nil
        }
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertEqual(model.notice, .filled(isProduction: false))
        XCTAssertNil(session.runtimeConnectionIssue)
        XCTAssertNil(session.aiLease, "The fill must not leave the keyboard locked")

        // The lease was given back, so a second fill has to take a fresh one.
        model.present(for: session)
        model.stageReviewedCandidateForTesting(AICommandSuggestion(
            command: "printf '__AI_FILLED_AGAIN__'", explanation: "fixture"))
        model.fillSelectedCommand(in: workspace)
        try await waitUntil("second fill reached the PTY") {
            session.controller.visibleScreenText().contains("__AI_FILLED_AGAIN__") && session.aiLease == nil
        }
        XCTAssertEqual(model.notice, .filled(isProduction: false))

        // A lease held by someone else is not the panel's to borrow.
        let held = expectation(description: "Foreign lease acquired")
        session.changeAIControl(action: .acquireControl, owner: "other-owner", archiveDirectory: root.appendingPathComponent("archives")) { result in
            if case .failure(let error) = result { XCTFail("Acquire failed: \(error)") }
            held.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)
        model.present(for: session)
        model.stageReviewedCandidateForTesting(AICommandSuggestion(
            command: "printf '__AI_MUST_NOT_FILL__'", explanation: "fixture"))
        model.fillSelectedCommand(in: workspace)
        XCTAssertEqual(model.phase, .failed)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__AI_MUST_NOT_FILL__"))
        XCTAssertEqual(session.aiLease?.owner, "other-owner")
    }

    func testDisconnectedInputRetainsReconnectIssue() {
        XCTAssertEqual(TerminalRuntimeInputQueue.rejectedEnqueueIssue(connected: false, byteCount: 1), .disconnected)
        XCTAssertEqual(TerminalRuntimeInputQueue.rejectedEnqueueIssue(connected: false,
            byteCount: TerminalRuntimeLimits.maximumOutputBytes + 1), .disconnected)
        XCTAssertEqual(TerminalRuntimeInputQueue.rejectedEnqueueIssue(connected: true, byteCount: 1), .inputRejected)
    }

    func testRuntimeDiagnosticCannotExposeRejectedPayload() throws {
        XCTAssertEqual(TerminalRuntimeConnectionError.timedOut.diagnosticCode, "timed_out")
        XCTAssertEqual(TerminalRuntimeConnectionError.rejected("control_changed").diagnosticCode, "control_changed")
        XCTAssertEqual(TerminalRuntimeConnectionError.rejected("/private/example?token=secret").diagnosticCode, "rejected")
        // Tool responses print localizedDescription. A bridged NSError hides the
        // rejection code behind "error 0", which reads as a socket failure.
        XCTAssertEqual(TerminalRuntimeConnectionError.rejected("control_changed").errorDescription,
            L10n.string("runtime.error.control_changed"))
        XCTAssertEqual(TerminalRuntimeConnectionError.unavailable.errorDescription,
            L10n.string("runtime.error.unavailable"))
        XCTAssertEqual(TerminalRuntimeConnectionError.rejected("/private/example?token=secret").errorDescription,
            L10n.format("runtime.error.rejected", "rejected"))
        XCTAssertFalse(TerminalRuntimeConnectionError.rejected("/private/example?token=secret")
            .errorDescription?.contains("token") ?? true)
        let metadata = TerminalToolRuntimeSnapshot(pid: 123, generation: UUID(), connected: false,
            errorCode: "timed_out", errorStage: "subscription")
        let data = try JSONEncoder().encode(metadata)
        XCTAssertEqual(try JSONDecoder().decode(TerminalToolRuntimeSnapshot.self, from: data), metadata)
    }

    private static let echoControlledShell = "stty sane echo; printf '__MODE_READY\\n'; while IFS= read -r line; do eval \"$line\"; done"
    private var process: Process?
    private var root: URL?
    private var viewers: [TerminalHostController] = []
    private var windows: [NSWindow] = []
    private var fixtureSSHProfiles: [SSHConnectionProfile] = []

    override func tearDown() {
        for viewer in viewers { viewer.terminate() }
        for window in windows { window.close() }
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        if let root { try? FileManager.default.removeItem(at: root) }
        for profile in fixtureSSHProfiles {
            let file = SSHConfigMaterializer.configFileURL(for: profile)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { XCTFail("Could not remove owned SSH fixture: \(error.localizedDescription)") }
            }
        }
        fixtureSSHProfiles.removeAll()
        viewers.removeAll(); windows.removeAll(); process = nil; root = nil
        super.tearDown()
    }

    private func waitUntil(_ label: String = "state", _ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let state = viewers.map {
            "connected=\($0.runtimeHandle?.connected == true),metadata=\($0.runtimeHandle?.info != nil),error=\(String(describing: $0.runtimeHandle?.lastError)),inputError=\($0.runtimeInputErrorCode ?? "nil"),inputSequence=\($0.runtimeHandle?.info?.nextInputSequence ?? 0),characters=\($0.visibleScreenText().count)"
        }.joined(separator: "; ")
        for (index, viewer) in viewers.enumerated() {
            let attachment = XCTAttachment(string: String(viewer.visibleScreenText().prefix(4_000)))
            attachment.name = "private-fixture-terminal-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTFail("Runtime view timed out at \(label): \(state)")
        throw TerminalRuntimeConnectionError.timedOut
    }

    private func startService() async throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/qrv-\(UUID().uuidString.prefix(12))", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/museterm-runtime")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "Embedded helper must be built and signed with the application")
        let process = Process()
        self.process = process
        process.executableURL = helper; process.arguments = ["--root", root.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        try await waitUntil("helper readiness") { FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-capability").path) }
        return (root, helper)
    }

    private func prepare(_ handle: TerminalRuntimeSessionHandle) async throws -> TerminalRuntimeInputPreparation {
        try await withCheckedThrowingContinuation { continuation in
            handle.prepareInput { continuation.resume(with: $0) }
        }
    }

    func testReplayBoundarySplitsOnlyPreviouslyRenderedBytes() throws {
        let generation = UUID()
        var response = TerminalRuntimeResponse(serviceEpoch: UUID(), id: UUID(), action: .subscribe)
        response.data = Data(repeating: 65, count: 10)
        response.cursor = .init(generation: generation, offset: 110)
        XCTAssertEqual(try TerminalRuntimeReplayBoundary.historicalBytes(in: response,
            renderedThrough: .init(generation: generation, offset: 105)), 5)
        XCTAssertEqual(try TerminalRuntimeReplayBoundary.historicalBytes(in: response,
            renderedThrough: .init(generation: generation, offset: 90)), 0)
        XCTAssertEqual(try TerminalRuntimeReplayBoundary.historicalBytes(in: response,
            renderedThrough: .init(generation: generation, offset: 120)), 10)
        XCTAssertThrowsError(try TerminalRuntimeReplayBoundary.historicalBytes(in: response,
            renderedThrough: .init(generation: UUID(), offset: 105)))
    }

    func testTruncatedTUIReplayExitsToShellWithoutResidueOnOriginalPTY() async throws {
        let (root, helper) = try await startService()
        let original = TerminalSession(sequence: 1)
        let program = "STDOUT.sync=true; system('stty','raw','-echo'); "
            + "STDOUT.write(\"\\e[?1049h\" + ' ' * 1100000 + \"\\e[2J\\e[H__ALT_READY__\\e[12;1H__TUI_FOOTER__\"); "
            + "STDIN.read(1); STDOUT.write(\"\\e[?1049l__SHELL_AFTER_TUI__\"); sleep 20"
        let launch = TerminalRuntimeLaunch(executable: "/usr/bin/ruby", arguments: ["-e", program],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
        attach(original, launch: launch, root: root, helper: helper)
        try await waitUntil("original alternate screen ready") { original.controller.visibleScreenText().contains("__TUI_FOOTER__") }
        let info = try XCTUnwrap(original.runtimeInfo)
        XCTAssertGreaterThan(info.outputOffset, UInt64(TerminalRuntimeOutputJournal.defaultCapacity))
        original.controller.detachRuntimeViewer()
        let restored = TerminalSession(sequence: 2, id: original.id)
        restored.runtimeGenerationToRestore = info.generation
        attach(restored, launch: launch, root: root, helper: helper)
        try await waitUntil("truncated alternate replay complete") {
            restored.controller.visibleScreenText().contains("__TUI_FOOTER__") && restored.runtimeRenderedCursor?.offset == info.outputOffset
        }
        restored.controller.sendProcessInput(bytes: [0x03])
        try await waitUntil("shell after replayed TUI exit") { restored.controller.visibleScreenText().contains("__SHELL_AFTER_TUI__") }
        XCTAssertFalse(restored.controller.visibleScreenText().contains("__TUI_FOOTER__"))
        XCTAssertEqual(restored.runtimeInfo?.pid, info.pid)
        XCTAssertEqual(restored.runtimeInfo?.generation, info.generation)
    }

    func testMouseReportsReachActualPTYThroughHumanInputQueue() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        let reports = ["\u{1b}[<0;5;6M", "\u{1b}[<0;5;6m", "\u{1b}[<64;5;6M", "\u{1b}[<65;5;6M"]
        let expected = reports.joined()
        let script = "stty raw -echo; printf '\\033[?1000h\\033[?1006h__MOUSE_READY\\n'; "
            + "dd bs=1 count=\(expected.utf8.count) 2>/dev/null | od -An -tx1 | tr -d ' \\n'; "
            + "printf '\\n__MOUSE_DONE\\n'; sleep 20"
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("mouse fixture ready") {
            session.controller.runtimeHandle?.connected == true && session.controller.visibleScreenText().contains("__MOUSE_READY")
        }
        let view = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        // The fixture reads four reports at fixed cells, so the view reports them directly instead
        // of deriving the cell from a window click.
        view.sendMouseEvent(button: 0, release: false, col: 4, row: 5)
        view.sendMouseEvent(button: 0, release: true, col: 4, row: 5)
        view.sendMouseEvent(button: 4, release: false, col: 4, row: 5)
        view.sendMouseEvent(button: 5, release: false, col: 4, row: 5)
        try await waitUntil("actual mouse bytes received by PTY") {
            session.controller.visibleScreenText().contains("__MOUSE_DONE")
        }
        let hex = expected.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(session.controller.visibleScreenText().filter { !$0.isWhitespace }.contains(hex))
        XCTAssertNil(session.runtimeConnectionIssue)
    }

    func testBackendLeaseRejectsMouseWithoutBypassingOwnership() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "stty raw -echo; printf '\\033[?1006h__MOUSE_LOCK_READY\\n'; sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("mouse lease fixture ready") {
            session.controller.runtimeHandle?.connected == true && session.controller.visibleScreenText().contains("__MOUSE_LOCK_READY")
        }
        let acquired = expectation(description: "mouse fixture takeover ACK")
        session.changeAIControl(action: .acquireControl, owner: "mouse-fixture", archiveDirectory: root.appendingPathComponent("archives")) { result in
            if case .failure(let error) = result { XCTFail("Acquire failed: \(error)") }
            acquired.fulfill()
        }
        await fulfillment(of: [acquired], timeout: 5)
        let view = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        view.sendMouseEvent(button: 4, release: false, col: 4, row: 5)
        try await waitUntil("locked mouse input rejected") { session.runtimeConnectionIssue == .inputRejected }
        XCTAssertEqual(session.aiLease?.owner, "mouse-fixture")
        XCTAssertFalse(TerminalRuntimeReplyPolicy.allows(Data("\u{1b}[<64;5;6M".utf8)))
    }

    func testHistoricalFeedIsSilentWhileNewBytesInSameFrameRemainLive() async throws {
        let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        var bells = 0
        var replies: [Data] = []
        var observed = Data()
        view.onTerminalBell = { bells += 1 }
        view.externalSend = { bytes, _ in replies.append(Data(bytes)); return true }
        view.onReceivedProcessData = { bytes in observed.append(contentsOf: bytes); return false }
        let history = Data("old\u{7}\u{1b}[5n".utf8)
        let live = Data("new\u{7}\u{1b}[5n".utf8)
        await withCheckedContinuation { continuation in
            view.receiveExternal(history + live, historicalBytes: history.count) { continuation.resume() }
        }
        XCTAssertEqual(bells, 1)
        XCTAssertEqual(observed, live)
        XCTAssertEqual(replies, [Data("\u{1b}[0n".utf8)])
        XCTAssertFalse(view.isReplayingHistoricalOutput)
    }

    func testRestoredViewerDoesNotRingOldBellButKeepsDetachedPeriodBell() async throws {
        let (root, helper) = try await startService()
        let original = TerminalSession(sequence: 1)
        let launch = TerminalRuntimeLaunch(executable: "/bin/sh", arguments: ["-c", "printf '__OLD_BELL\\a'; sleep 1; printf '__NEW_BELL\\a'; sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
        attach(original, launch: launch, root: root, helper: helper)
        try await waitUntil("old output has actually rendered") {
            original.controller.visibleScreenText().contains("__OLD_BELL") && original.runtimeRenderedCursor != nil
        }
        let info = try XCTUnwrap(original.runtimeInfo)
        let cursor = try XCTUnwrap(original.runtimeRenderedCursor)
        original.controller.detachRuntimeViewer()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let restored = TerminalSession(sequence: 2, id: original.id)
        restored.runtimeGenerationToRestore = info.generation
        restored.runtimeRenderedCursorToRestore = cursor
        var bells = 0
        let terminal = try XCTUnwrap(restored.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        terminal.onTerminalBell = { bells += 1 }
        attach(restored, launch: launch, root: root, helper: helper)
        try await waitUntil("replay and detached period output") { restored.controller.visibleScreenText().contains("__NEW_BELL") }
        XCTAssertEqual(restored.runtimeInfo?.pid, info.pid)
        XCTAssertEqual(bells, 1)
        XCTAssertGreaterThan(try XCTUnwrap(restored.runtimeRenderedCursor).offset, cursor.offset)
    }

    private func attach(_ session: TerminalSession, launch: TerminalRuntimeLaunch, root: URL, helper: URL,
                        ready: @escaping () -> Void = {}) {
        let controller = session.controller
        let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.container
        controller.layoutTerminalViews()
        windows.append(window); viewers.append(controller)
        controller.startRuntime(launch, root: root, executable: helper, ready: ready)
    }

    func testActualSwiftTermViewerDetachesAndRestoresOriginalPTY() async throws {
        let (root, helper) = try await startService()
        let original = TerminalSession(sequence: 1)
        let launch = TerminalRuntimeLaunch(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
        attach(original, launch: launch, root: root, helper: helper)
        // A subscription ACK is not a shell-input-ready barrier. Use the same
        // real PTY fixture as the preflight tests, with an observable ready line.
        try await waitUntil("first viewer and shell ready") {
            original.controller.runtimeHandle?.connected == true && original.controller.visibleScreenText().contains("__MODE_READY")
        }
        original.controller.sendProcessInput(bytes: Array("stty -echo; printf '__VIEW_FIRST\\n'\n".utf8))
        try await waitUntil("first rendered output") { original.controller.visibleScreenText().components(separatedBy: "\n").contains("__VIEW_FIRST") }
        let info = try XCTUnwrap(original.runtimeInfo)
        original.controller.detachRuntimeViewer()
        let restored = TerminalSession(sequence: 2, id: original.id)
        restored.runtimeGenerationToRestore = info.generation
        // A valid attach must ignore this launch descriptor and keep the old PID.
        let mustNotLaunch = TerminalRuntimeLaunch(executable: "/museterm-must-not-launch", directory: root.path)
        attach(restored, launch: mustNotLaunch, root: root, helper: helper)
        try await waitUntil("restored viewer subscription") { restored.controller.runtimeHandle?.connected == true }
        XCTAssertEqual(restored.runtimeInfo?.pid, info.pid)
        XCTAssertEqual(restored.runtimeInfo?.generation, info.generation)
        restored.controller.sendProcessInput(bytes: Array("printf '\\n__VIEW_RESTORED\\n'\n".utf8))
        try await waitUntil("restored rendered output") { restored.controller.visibleScreenText().components(separatedBy: "\n").contains("__VIEW_RESTORED") }
        XCTAssertTrue(restored.hasRunningProcess)
    }

    func testFirstAttachSynchronizesActualPTYSizeAfterEarlyLayout() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"],
            directory: root.path, columns: 140, rows: 40), root: root, helper: helper)
        let terminal = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        try await waitUntil("first PTY size matches final layout") {
            let dimensions = terminal.terminalDimensions
            return session.controller.runtimeHandle?.connected == true && session.runtimeInfo?.columns == dimensions.cols &&
                session.runtimeInfo?.rows == dimensions.rows
        }
        let dimensions = terminal.terminalDimensions
        XCTAssertNotEqual(dimensions.cols, 140)
        let expected = "\(dimensions.rows) \(dimensions.cols)"
        session.controller.sendProcessInput(bytes: Array("stty size\n".utf8))
        try await waitUntil("stty confirms real PTY dimensions") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == expected }
        }
    }

    func testExitedRuntimeRestartCreatesNewGenerationAndRunsStartupOnce() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "printf '__OLD_EXITED\\n'"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root.path), root: root, helper: helper)
        try await waitUntil("original process exited") {
            session.runtimeInfo?.running == false && session.controller.visibleScreenText().contains("__OLD_EXITED")
        }
        let previous = try XCTUnwrap(session.runtimeInfo)
        let cursor = try XCTUnwrap(session.runtimeRenderedCursor)
        session.runtimeRenderedCursorToRestore = cursor
        var startups = 0
        session.controller.startRuntime(.init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color",
                "PS1": "__RESTART_SHELL_READY> "],
            directory: root.path), root: root, executable: helper, restarting: previous) { startups += 1 }
        try await waitUntil("new process attached") {
            session.controller.runtimeHandle?.connected == true && session.runtimeInfo?.running == true && startups == 1
        }
        let restarted = try XCTUnwrap(session.runtimeInfo)
        XCTAssertEqual(restarted.id, previous.id)
        XCTAssertNotEqual(restarted.pid, previous.pid)
        XCTAssertNotEqual(restarted.generation, previous.generation)
        XCTAssertEqual(session.runtimeGenerationToRestore, restarted.generation)
        XCTAssertNil(session.runtimeRenderedCursorToRestore)
        // Subscription readiness precedes interactive sh's readline setup,
        // which changes ECHO. Sending during that transition is correctly
        // rejected by write-time context validation. Keep the real interactive
        // shell, and observe its prompt rather than adding a timing delay.
        try await waitUntil("restarted interactive shell prompt") {
            session.controller.visibleScreenText().contains("__RESTART_SHELL_READY>")
        }
        session.controller.sendProcessInput(bytes: Array("printf '\\n__NEW_INPUT_OK\\n'\n".utf8))
        try await waitUntil("new process acknowledges input") {
            (session.controller.runtimeHandle?.info?.nextInputSequence ?? 0) > restarted.nextInputSequence
        }
        try await waitUntil("input targets new process") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__NEW_INPUT_OK")
        }
        XCTAssertEqual(startups, 1)
    }

    private func refusedLocalSSHProfile(automaticReconnect: Bool) throws -> (SSHConnectionProfile, Int32) {
        // Reserve an ephemeral loopback port without listening: real ssh must
        // fail locally, without contacting a server or reading user credentials.
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalRuntimeConnectionError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else { Darwin.close(fd); throw TerminalRuntimeConnectionError.unavailable }
        let profile = SSHConnectionProfile(name: "isolated-refused-loopback", host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)),
            extraOptions: ["BatchMode=yes", "ConnectTimeout=1", "ConnectionAttempts=1", "IdentitiesOnly=yes", "IdentityFile=none", "UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=yes"],
            connectionReuseEnabled: false,
            automaticReconnectEnabled: automaticReconnect, automaticReconnectAttempts: 1, automaticReconnectDelaySeconds: 1)
        fixtureSSHProfiles.append(profile)
        return (profile, fd)
    }

    private func authenticatedSSHProfile(_ fixture: TerminalRuntimeSSHTestFixture, automatic: Bool) -> SSHConnectionProfile {
        let metadata = fixture.metadata
        let profile = SSHConnectionProfile(name: "isolated-authenticated-loopback", host: "127.0.0.1",
            user: metadata.user, port: metadata.port, identityFiles: [metadata.root + "/client"],
            extraOptions: ["BatchMode=yes", "ConnectTimeout=2", "ConnectionAttempts=1", "IdentityAgent=none",
                "UserKnownHostsFile=" + metadata.root + "/known_hosts", "GlobalKnownHostsFile=/dev/null", "StrictHostKeyChecking=yes"],
            startupCommands: ["printf '\\n__PROFILE_STARTUP_%s\\n' \"$$\""], connectionReuseEnabled: false,
            automaticReconnectEnabled: automatic, automaticReconnectAttempts: 1, automaticReconnectDelaySeconds: 1,
            remoteShellIntegrationEnabled: false)
        fixtureSSHProfiles.append(profile)
        return profile
    }

    private func profileStartupMarker(_ session: TerminalSession) -> String? {
        session.controller.visibleScreenText().components(separatedBy: "\n").last {
            $0.hasPrefix("__PROFILE_STARTUP_") && $0.dropFirst("__PROFILE_STARTUP_".count).allSatisfy(\.isNumber)
        }
    }

    func testAuthenticatedSSHProfileRestoresViewerAndManuallyReconnectsAfterNetworkDrop() async throws {
        let fixture = try TerminalRuntimeSSHTestFixture()
        defer { do { try fixture.stop() } catch { XCTFail("Owned SSH fixture cleanup failed: \(error)") } }
        let (root, helper) = try await startService()
        let profile = authenticatedSSHProfile(fixture, automatic: false)
        let original = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        defer { original.controller.terminate() }
        attach(original, launch: .init(executable: "/bin/sh", arguments: ["-c", "exit 255"], directory: root.path), root: root, helper: helper)
        try await waitUntil("manual authenticated source exited") { original.runtimeInfo?.running == false }
        original.controller.reconnectSSH()
        try await waitUntil("Profile authenticated and startup command executed") { self.profileStartupMarker(original) != nil }
        let connected = try XCTUnwrap(original.runtimeInfo)
        let firstMarker = try XCTUnwrap(profileStartupMarker(original))
        let cursor = try XCTUnwrap(original.runtimeRenderedCursor)
        original.controller.detachRuntimeViewer()
        let restored = TerminalSession(sequence: 2, launchConfiguration: .ssh(profile), id: original.id)
        defer { restored.controller.terminate() }
        restored.runtimeGenerationToRestore = connected.generation
        restored.runtimeRenderedCursorToRestore = cursor
        var restoreStartupCalls = 0
        attach(restored, launch: .init(executable: "/must-not-replace-ssh", directory: root.path), root: root, helper: helper) {
            restoreStartupCalls += 1
        }
        try await waitUntil("same authenticated SSH viewer restored") { restored.controller.runtimeHandle?.connected == true }
        XCTAssertEqual(restored.runtimeInfo?.pid, connected.pid)
        XCTAssertEqual(restored.runtimeInfo?.generation, connected.generation)
        XCTAssertEqual(restoreStartupCalls, 0)
        restored.controller.sendProcessInput(bytes: Array("printf '\\n__PROFILE_RESTORED_INPUT\\n'\n".utf8))
        try await waitUntil("restored Profile accepts input") {
            restored.controller.visibleScreenText().components(separatedBy: "\n").contains("__PROFILE_RESTORED_INPUT")
        }
        try fixture.disconnect()
        try await waitUntil("authenticated transport really exited") { restored.runtimeInfo?.running == false }
        XCTAssertEqual(restored.runtimeInfo?.generation, connected.generation)
        restored.controller.reconnectSSH()
        try await waitUntil("manual Profile reconnect authenticated new remote shell") {
            restored.runtimeInfo?.running == true && restored.runtimeInfo?.generation != connected.generation &&
                self.profileStartupMarker(restored).map { $0 != firstMarker } == true
        }
        XCTAssertEqual(restored.runtimeInfo?.id, connected.id)
        XCTAssertNotEqual(restored.runtimeInfo?.pid, connected.pid)
        restored.controller.sendProcessInput(bytes: Array("printf '\\n__PROFILE_MANUAL_RECONNECT_OK\\n'\n".utf8))
        try await waitUntil("manual reconnected Profile accepts input") {
            restored.controller.visibleScreenText().components(separatedBy: "\n").contains("__PROFILE_MANUAL_RECONNECT_OK")
        }
    }

    func testAuthenticatedSSHProfileAutomaticallyReconnectsOnceThenHonorsLimit() async throws {
        let fixture = try TerminalRuntimeSSHTestFixture()
        defer { do { try fixture.stop() } catch { XCTFail("Owned SSH fixture cleanup failed: \(error)") } }
        let (root, helper) = try await startService()
        let profile = authenticatedSSHProfile(fixture, automatic: true)
        let descriptor = try SSHConfigMaterializer.descriptor(for: profile)
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        defer { session.controller.terminate() }
        attach(session, launch: .init(executable: descriptor.executable, arguments: descriptor.args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("initial authenticated SSH shell") { session.controller.visibleScreenText().contains("__PROFILE_SHELL_") }
        let initial = try XCTUnwrap(session.runtimeInfo)
        try fixture.disconnect(reset: true)
        try await waitUntil("automatic Profile reconnect authenticated") {
            session.runtimeInfo?.running == true && session.runtimeInfo?.generation != initial.generation &&
                self.profileStartupMarker(session) != nil
        }
        let reconnected = try XCTUnwrap(session.runtimeInfo)
        XCTAssertEqual(reconnected.id, initial.id)
        XCTAssertNotEqual(reconnected.pid, initial.pid)
        session.controller.sendProcessInput(bytes: Array("printf '\\n__PROFILE_AUTO_RECONNECT_OK\\n'\n".utf8))
        try await waitUntil("automatic reconnected Profile accepts input") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__PROFILE_AUTO_RECONNECT_OK")
        }
        try fixture.disconnect(reset: true)
        try await waitUntil("second transport loss") { session.runtimeInfo?.running == false }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(session.runtimeInfo?.generation, reconnected.generation)
        XCTAssertFalse(session.runtimeInfo?.running == true, "Configured retry budget must prevent another authentication attempt")
    }

    func testAuthenticatedSSHProfileHostKeyFailureNeverAutomaticallyReconnects() async throws {
        let fixture = try TerminalRuntimeSSHTestFixture()
        defer { do { try fixture.stop() } catch { XCTFail("Owned SSH fixture cleanup failed: \(error)") } }
        let (root, helper) = try await startService()
        var profile = authenticatedSSHProfile(fixture, automatic: true)
        profile.extraOptions = profile.extraOptions.map {
            $0.hasPrefix("UserKnownHostsFile=") ? "UserKnownHostsFile=" + fixture.metadata.root + "/wrong_known_hosts" : $0
        }
        let descriptor = try SSHConfigMaterializer.descriptor(for: profile)
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        defer { session.controller.terminate() }
        attach(session, launch: .init(executable: descriptor.executable, arguments: descriptor.args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("initial refused SSH identity exists") { session.runtimeInfo != nil }
        let refused = try XCTUnwrap(session.runtimeInfo)
        try await waitUntil("actual pinned host key refused") {
            session.runtimeInfo?.running == false && session.controller.visibleScreenText().contains("Host key verification failed")
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(session.runtimeInfo?.generation, refused.generation)
        XCTAssertEqual(session.runtimeInfo?.pid, refused.pid)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let retained = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
        XCTAssertEqual(retained.generation, refused.generation)
        XCTAssertFalse(retained.running, "Security failure must not silently retry authentication")
    }

    func testManualSSHReconnectReplacesExitedRuntimeInsteadOfAttachingIt() async throws {
        let (root, helper) = try await startService()
        let (profile, socket) = try refusedLocalSSHProfile(automaticReconnect: false)
        defer { Darwin.close(socket) }
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "exit 255"],
            directory: root.path), root: root, helper: helper)
        try await waitUntil("manual reconnect source exited") { session.runtimeInfo?.running == false }
        let original = try XCTUnwrap(session.runtimeInfo)
        session.controller.reconnectSSH()
        try await waitUntil("manual SSH reconnect started a new real process") {
            session.runtimeInfo?.generation != original.generation && session.runtimeInfo?.running == false
        }
        XCTAssertEqual(session.runtimeInfo?.id, original.id)
        XCTAssertNotEqual(session.runtimeInfo?.pid, original.pid)
        XCTAssertEqual(session.runtimeInfo?.exitStatus, 255)
        XCTAssertTrue(session.controller.visibleScreenText().contains("127.0.0.1"))
    }

    func testAutomaticSSHReconnectCreatesNewGenerationWithinAttemptLimit() async throws {
        let (root, helper) = try await startService()
        let (profile, socket) = try refusedLocalSSHProfile(automaticReconnect: true)
        defer { Darwin.close(socket) }
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(profile))
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "exit 255"],
            directory: root.path), root: root, helper: helper)
        try await waitUntil("automatic reconnect source exited") { session.runtimeInfo?.running == false }
        let original = try XCTUnwrap(session.runtimeInfo)
        try await waitUntil("automatic reconnect produces replacement") {
            session.runtimeInfo?.generation != original.generation && session.runtimeInfo?.running == false
        }
        let replacement = try XCTUnwrap(session.runtimeInfo)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(session.runtimeInfo?.generation, replacement.generation, "One allowed retry must not loop forever")
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.exitStatus, 255)
    }

    func testMissingRecoveryRecordDiscoversAndAttachesSameRealPTYWithoutStartup() async throws {
        let (root, _) = try await startService()
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        var request = TerminalRuntimeRequest(action: .create)
        request.launch = .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
        let original = try XCTUnwrap(connection.request(request).session)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let workspace = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        XCTAssertTrue(workspace.tabs.isEmpty, "Do not race discovery with an unnecessary new shell")
        try await waitUntil("orphan discovery") { !workspace.runtimeDiscoveryInProgress }
        XCTAssertEqual(workspace.tabs.map(\.id), [original.id])
        let recovered = try XCTUnwrap(workspace.selectedTab)
        XCTAssertTrue(recovered.runtimeAttachOnly)
        XCTAssertThrowsError(try workspace.splitTerminal(recovered.id, axis: .horizontal))
        XCTAssertThrowsError(try workspace.saveSnapshot(), "Unknown launch configuration must not become a recreatable local shell")
        XCTAssertEqual(recovered.runtimeGenerationToRestore, original.generation)
        // Use the real production start path: only the saved identity may be
        // attached. The sentinel executable must never be spawned.
        let controller = recovered.controller
        let window = NSWindow(contentRect: .init(x: -2_000, y: -2_000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.container
        windows.append(window); viewers.append(controller)
        controller.layoutTerminalViews()
        recovered.startProcessIfNeeded()
        try await waitUntil("discovered PTY viewer connected") { controller.runtimeHandle?.connected == true }
        XCTAssertEqual(recovered.runtimeInfo?.pid, original.pid)
        XCTAssertEqual(recovered.runtimeInfo?.generation, original.generation)
        XCTAssertFalse(controller.runtimeHandle?.createdNewPTY ?? true)
        XCTAssertTrue(controller.toolSnapshot(index: 1, isSelected: true, maxHistoryCharacters: 0).runtime?.attachOnly == true)
        controller.sendProcessInput(bytes: Array("printf '\\n__ORPHAN_INPUT_OK\\n'\n".utf8))
        try await waitUntil("recovered original process accepts input") {
            controller.visibleScreenText().components(separatedBy: "\n").contains("__ORPHAN_INPUT_OK")
        }
        let listed = try XCTUnwrap(connection.request(.init(action: .list)).sessions)
        XCTAssertEqual(listed.count, 1)
        try lifecycle.prepareForExit()
        let saved = try TerminalRuntimeWorkspaceStore(root: root).load(workspace.runtimeWorkspaceID)
        XCTAssertEqual(saved.snapshot.tabs.first?.runtimeAttachOnly, true)
        XCTAssertEqual(saved.snapshot.tabs.first?.runtimeGeneration, original.generation)
    }

    func testDiscoveryReservesOtherWindowsAndUnopenedWorkspaceRecords() async throws {
        let (root, _) = try await startService()
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        var request = TerminalRuntimeRequest(action: .create)
        request.launch = .init(executable: "/bin/sh", arguments: ["-c", "sleep 20"], directory: root.path)
        let original = try XCTUnwrap(connection.request(request).session)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let first = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        let second = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        try await waitUntil("two concurrent window discoveries") {
            !first.runtimeDiscoveryInProgress && !second.runtimeDiscoveryInProgress
        }
        XCTAssertEqual((first.tabs + second.tabs).filter { $0.id == original.id }.count, 1)
        try lifecycle.prepareForExit()
        // A separate, newly created UI lifecycle must reserve the retained
        // record even when another window is selected before it is opened.
        let reopened = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let a = reopened.makeWorkspace(automaticallyStartProcesses: false)
        try await waitUntil("unopened window record remains reserved") { !a.runtimeDiscoveryInProgress }
        XCTAssertEqual(a.tabs.count, 1, "Discovery must not take a terminal reserved by the unopened second record")
        let b = reopened.makeWorkspace(automaticallyStartProcesses: false)
        try await waitUntil("saved records and backend discovery converge") {
            !a.runtimeDiscoveryInProgress && !b.runtimeDiscoveryInProgress
        }
        XCTAssertEqual((a.tabs + b.tabs).filter { $0.id == original.id }.count, 1)
        XCTAssertEqual(try connection.request(.init(action: .list)).sessions?.count, 1)
    }

    func testCorruptRecoveryRecordIsRetainedWhileRealOrphanIsFound() async throws {
        let (root, _) = try await startService()
        let store = TerminalRuntimeWorkspaceStore(root: root)
        let seed = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let record = try seed.runtimeWorkspaceRecord()
        try store.save(record)
        let corrupt = store.directory.appendingPathComponent("\(record.workspaceID).json")
        try Data("broken fixture".utf8).write(to: corrupt)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        var request = TerminalRuntimeRequest(action: .create)
        request.launch = .init(executable: "/bin/sh", arguments: ["-c", "sleep 20"], directory: root.path)
        let original = try XCTUnwrap(connection.request(request).session)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let recovered = lifecycle.makeWorkspace(automaticallyStartProcesses: false)
        try await waitUntil("corrupt record does not hide retained process") { !recovered.runtimeDiscoveryInProgress }
        XCTAssertTrue(recovered.runtimeRecoveryIssue)
        XCTAssertEqual(recovered.tabs.map(\.id), [original.id])
        try lifecycle.prepareForExit()
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("broken fixture".utf8))
    }

    func testWorkspaceExitPersistsIdentityAndRestoresSameRealPTYWithoutStartupInput() async throws {
        let (root, helper) = try await startService()
        let original = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let first = try XCTUnwrap(original.selectedTab)
        attach(first, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("workspace original PTY") { first.controller.runtimeHandle?.connected == true }
        let info = try XCTUnwrap(first.runtimeInfo)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        lifecycle.attach(original)
        try lifecycle.prepareForExit()
        let record = try TerminalRuntimeWorkspaceStore(root: root).load(original.runtimeWorkspaceID)
        XCTAssertEqual(record.snapshot.tabs.first?.runtimeGeneration, info.generation)
        XCTAssertEqual(record.snapshot.tabs.first?.runtimeRequiresExisting, true)
        let recovered = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil, restoringRuntimeRecord: record)
        let second = try XCTUnwrap(recovered.selectedTab)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(recovered.projectLayout, original.projectLayout)
        let controller = second.controller
        let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.container
        controller.layoutTerminalViews(); windows.append(window); viewers.append(controller)
        var startupWasCalled = false
        controller.startRuntime(.init(executable: "/museterm-must-never-launch", directory: root.path), root: root, executable: helper) {
            startupWasCalled = true
        }
        try await waitUntil("workspace recovered PTY") { controller.runtimeHandle?.connected == true }
        XCTAssertEqual(second.runtimeInfo?.pid, info.pid)
        XCTAssertEqual(second.runtimeInfo?.generation, info.generation)
        XCTAssertFalse(startupWasCalled, "Reattaching must not send profile startup commands to a live TUI")
        controller.sendProcessInput(bytes: Array("printf '\\n__WORKSPACE_RESUMED\\n'\n".utf8))
        try await waitUntil("recovered workspace accepts input") { controller.visibleScreenText().components(separatedBy: "\n").contains("__WORKSPACE_RESUMED") }
    }

    func testMissingPersistedRuntimeDoesNotCreateReplacementShell() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        session.runtimeGenerationToRestore = UUID()
        session.runtimeRequiresExisting = true
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "printf '__MUST_NOT_LAUNCH'"], directory: root.path), root: root, helper: helper)
        try await waitUntil("missing original is reported") { session.controller.runtimeHandle?.lastError != nil }
        XCTAssertEqual(session.controller.runtimeHandle?.lastErrorStage, "startup")
        XCTAssertFalse(session.controller.runtimeHandle?.connected == true)
        XCTAssertNil(session.runtimeInfo)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__MUST_NOT_LAUNCH"))
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        XCTAssertTrue(try connection.request(.init(action: .list)).sessions?.isEmpty == true)
    }

    func testExistingRuntimeDiscoveredBeforeGenerationWasSavedDoesNotReplayStartup() async throws {
        let (root, helper) = try await startService()
        let original = TerminalSession(sequence: 1)
        attach(original, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("original discovered PTY") { original.controller.runtimeHandle?.connected == true }
        let pid = try XCTUnwrap(original.runtimeInfo?.pid)
        original.controller.detachRuntimeViewer()
        let recovered = TerminalSession(sequence: 2, id: original.id)
        var startupWasCalled = false
        attach(recovered, launch: .init(executable: "/museterm-do-not-relaunch", directory: root.path), root: root, helper: helper) {
            startupWasCalled = true
        }
        try await waitUntil("existing PTY discovered by UUID") { recovered.controller.runtimeHandle?.connected == true }
        XCTAssertEqual(recovered.runtimeInfo?.pid, pid)
        XCTAssertFalse(recovered.controller.runtimeHandle?.createdNewPTY == true)
        XCTAssertFalse(startupWasCalled)
    }

    func testSaveFailureKeepsOriginalViewerConnected() async throws {
        let (root, helper) = try await startService()
        let original = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(original.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("save failure original viewer") { session.controller.runtimeHandle?.connected == true }
        let invalidRoot = root.appendingPathComponent("invalid-store")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: invalidRoot.appendingPathComponent("workspaces"), withDestinationURL: root)
        let lifecycle = TerminalRuntimeWorkspaceLifecycle(root: invalidRoot, enabled: true)
        lifecycle.attach(original)
        XCTAssertThrowsError(try lifecycle.prepareForExit())
        XCTAssertTrue(session.controller.runtimeHandle?.connected == true)
        session.controller.sendProcessInput(bytes: Array("printf '\\n__SAVE_FAILED_STILL_RUNNING\\n'\n".utf8))
        try await waitUntil("original still accepts input after save failure") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__SAVE_FAILED_STILL_RUNNING")
        }
    }

    func testEmulatorDeviceReplyContinuesDuringBackendAILease() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        let script = "stty raw -echo; printf '__WAIT'; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[5n'; dd bs=1 count=4 2>/dev/null | od -An -t x1; sleep 2"
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("device-query program ready") { session.controller.visibleScreenText().contains("__WAIT") }
        _ = try XCTUnwrap(session.controller.runtimeHandle)
        let acquired = expectation(description: "Backend control acquired")
        session.changeAIControl(action: .acquireControl, owner: "view-probe", archiveDirectory: root.appendingPathComponent("archives")) { result in
            if case .failure = result { XCTFail("Could not acquire backend control") }
            XCTAssertEqual(session.aiLease?.owner, "view-probe", "The product mask follows the backend ACK")
            acquired.fulfill()
        }
        await fulfillment(of: [acquired], timeout: 5)
        let inputAck = expectation(description: "AI trigger written to real PTY")
        session.controller.sendToolInput(bytes: Array("g".utf8), owner: "view-probe") { result in
            if case .failure(let error) = result { XCTFail("Trigger rejected: \(error)") }
            inputAck.fulfill()
        }
        await fulfillment(of: [inputAck], timeout: 5)
        try await waitUntil("device reply through active lease") {
            let bytes = session.controller.visibleScreenText().split(whereSeparator: { $0.isWhitespace })
            return Array(bytes.suffix(4)) == ["1b", "5b", "30", "6e"]
        }
        XCTAssertEqual(session.runtimeInfo?.controlOwner, "view-probe")
        XCTAssertNil(session.runtimeConnectionIssue)
    }

    func testBackendLeaseReclaimRejectsDelayedAIInput() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("lease viewer subscription") { session.controller.runtimeHandle?.connected == true }
        XCTAssertThrowsError(try session.takeAIControl(owner: "queued-is-not-owned", archiveDirectory: root))
        let acquired = expectation(description: "Product takeover ACK")
        session.changeAIControl(action: .acquireControl, owner: "owner-a", archiveDirectory: root.appendingPathComponent("archives")) { result in
            if case .failure(let error) = result { XCTFail("Acquire failed: \(error)") }
            XCTAssertEqual(session.aiLease?.owner, "owner-a")
            XCTAssertNotNil(session.aiLease?.expiresAt)
            acquired.fulfill()
        }
        await fulfillment(of: [acquired], timeout: 5)
        let previousExpiry = try XCTUnwrap(session.aiLease?.expiresAt)
        let renewed = expectation(description: "Product renew ACK")
        session.changeAIControl(action: .renewControl, owner: "owner-a") { result in
            if case .failure(let error) = result { XCTFail("Renew failed: \(error)") }
            XCTAssertGreaterThanOrEqual(session.aiLease?.expiresAt ?? .distantPast, previousExpiry)
            renewed.fulfill()
        }
        await fulfillment(of: [renewed], timeout: 5)
        let wrongOwner = expectation(description: "Other owner cannot release")
        session.changeAIControl(action: .releaseControl, owner: "owner-b") { result in
            if case .success = result { XCTFail("Another owner released the lease") }
            XCTAssertEqual(session.aiLease?.owner, "owner-a")
            wrongOwner.fulfill()
        }
        await fulfillment(of: [wrongOwner], timeout: 5)
        session.releaseAIControl(reason: "human_unlock")
        try await waitUntil("human reclaim ACK") { session.aiLease == nil }
        XCTAssertNil(session.runtimeInfo?.controlOwner)
        XCTAssertThrowsError(try session.authorizeAIInput(owner: "owner-a"))
        let stale = expectation(description: "Delayed AI bytes rejected by service")
        XCTAssertTrue(session.controller.runtimeHandle!.send(Data("printf '__MUST_NOT_EXECUTE'\\n".utf8), source: .ai, owner: "owner-a") { result in
            if case .success = result { XCTFail("Stale AI write accepted") }
            stale.fulfill()
        })
        await fulfillment(of: [stale], timeout: 5)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__MUST_NOT_EXECUTE"))
    }

    func testPreparedInputRejectsChangedRealEchoBeforeWriting() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("echo preparation viewer") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        let initial = try await prepare(handle)
        XCTAssertTrue(initial.echoEnabled)
        session.controller.sendProcessInput(bytes: Array("stty -echo; printf '\\n__ECHO_NOW_OFF\\n'\n".utf8))
        try await waitUntil("echo changed by real PTY") { session.controller.visibleScreenText().components(separatedBy: "\n").contains("__ECHO_NOW_OFF") }
        let current = try await prepare(handle)
        XCTAssertFalse(current.echoEnabled)
        let rejected = expectation(description: "Stale echo context rejected")
        XCTAssertTrue(handle.sendPrepared(Data("printf '__STALE_ECHO_EXECUTED'\n".utf8), preparation: initial, source: .human, owner: nil) { result in
            if case .failure(TerminalRuntimeConnectionError.rejected(let reason)) = result { XCTAssertEqual(reason, "input_echo_changed") }
            else { XCTFail("Expected context rejection") }
            rejected.fulfill()
        })
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__STALE_ECHO_EXECUTED"))
        XCTAssertTrue(handle.connected, "Policy rejection must not disconnect the viewer")
        let afterRejection = try await prepare(handle)
        XCTAssertEqual(afterRejection.session.nextInputSequence, current.session.nextInputSequence,
            "A context rejection must not consume input sequence or replay the rejected text")
        session.controller.sendProcessInput(bytes: Array("printf '\\n__EXPLICIT_AFTER_REJECTION\\n'\n".utf8))
        try await waitUntil("explicit new input after context rejection") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__EXPLICIT_AFTER_REJECTION")
        }
        XCTAssertFalse(session.controller.visibleScreenText().contains("__STALE_ECHO_EXECUTED"))
        let afterExplicitInput = try await prepare(handle)
        XCTAssertEqual(afterExplicitInput.session.nextInputSequence, current.session.nextInputSequence + 1)
    }

    func testInputQueueUsesRealPreflightAndWaitsForApprovalAndWriteACK() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("input queue viewer") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        var approvals: [String] = []
        var committed = 0
        let queue = TerminalRuntimeInputQueue(handle: handle, approve: { bytes, echo, source, _ in
            XCTAssertTrue(echo); XCTAssertEqual(source, .human)
            let text = String(decoding: bytes, as: UTF8.self)
            approvals.append(text)
            return !text.contains("__APPROVAL_DENIED")
        }, committed: { _, _, response in
            XCTAssertEqual(response.echoEnabled, true); committed += 1
        }, failed: { error in XCTAssertTrue(error is TerminalAIControlError) })
        defer { queue.cancel() }
        let denied = expectation(description: "Rejected before write")
        let allowed = expectation(description: "Allowed input ACK")
        let sequence = try XCTUnwrap(handle.info).nextInputSequence
        let deniedText = Array("printf '__APPROVAL_DENIED'\n".utf8)
        let deniedFrame = EscapeSequences.bracketedPasteStart + deniedText + EscapeSequences.bracketedPasteEnd
        XCTAssertFalse(queue.enqueue(deniedFrame, source: .human, owner: nil, validationBytes: Array("harmless".utf8)))
        XCTAssertTrue(queue.enqueue(deniedFrame, source: .human, owner: nil, validationBytes: deniedText) { result in
            if case .success = result { XCTFail("Denied input was sent") }; denied.fulfill()
        })
        XCTAssertTrue(queue.enqueue(Array("printf '\\n__APPROVAL_ALLOWED\\n'\n".utf8), source: .human, owner: nil) { result in
            if case .failure(let error) = result { XCTFail("Allowed input failed: \(error)") }; allowed.fulfill()
        })
        await fulfillment(of: [denied, allowed], timeout: 5)
        try await waitUntil("only approved input executed") { session.controller.visibleScreenText().components(separatedBy: "\n").contains("__APPROVAL_ALLOWED") }
        XCTAssertEqual(approvals.count, 2); XCTAssertEqual(committed, 1)
        XCTAssertEqual(approvals.first, String(decoding: deniedText, as: UTF8.self))
        XCTAssertEqual(handle.info?.nextInputSequence, sequence + 1, "Denied paste must not send even its opening frame")
        XCTAssertFalse(session.controller.visibleScreenText().contains("__APPROVAL_DENIED"))
    }

    func testBracketedPasteIntoCleanInteractiveZshExecutesOnlyAfterReturn() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/zsh", arguments: ["-d", "-f", "-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path,
                "TERM": "xterm-256color", "PS1": "__PASTE_READY> "], directory: root.path), root: root, helper: helper)
        let terminal = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        try await waitUntil("clean zsh paste ready") {
            session.controller.visibleScreenText().contains("__PASTE_READY>") && terminal.terminalInputStateSnapshot()?.bracketedPasteMode == true
        }
        let beforeReturn = try XCTUnwrap(session.runtimeInfo).nextInputSequence
        terminal.setMarkedText("尚未提交的组合文本", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertTrue(terminal.sendPaste("printf '\\n__CLEAN_ZSH_PASTE_OK\\n'"))
        XCTAssertFalse(terminal.hasMarkedText(), "Paste must clear composition without submitting the old marked text")
        try await waitUntil("complete paste acknowledged once") {
            session.controller.runtimeHandle?.info?.nextInputSequence == beforeReturn + 1
        }
        XCTAssertFalse(session.controller.visibleScreenText().components(separatedBy: "\n").contains("__CLEAN_ZSH_PASTE_OK"))
        session.controller.sendProcessInput(bytes: [0x0d])
        try await waitUntil("clean zsh pasted command executed") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__CLEAN_ZSH_PASTE_OK")
        }
        XCTAssertFalse(session.controller.visibleScreenText().contains("bad pattern"))
        XCTAssertFalse(session.controller.visibleScreenText().contains("尚未提交的组合文本"))
    }

    func testRuntimeOutputDoesNotDismissRejectedInputUntilSuccessfulWrite() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path), root: root, helper: helper)
        try await waitUntil("input issue fixture ready") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        session.controller.sendProcessInput(bytes: Array(repeating: 0x61, count: TerminalRuntimeLimits.maximumOutputBytes + 1))
        XCTAssertEqual(session.runtimeConnectionIssue, .inputTooLarge)
        let output = expectation(description: "Independent backend output accepted")
        XCTAssertTrue(handle.send(Data("printf '\\n__OUTPUT_AFTER_REJECTION\\n'\n".utf8), source: .human) { result in
            if case .failure(let error) = result { XCTFail("Fixture input failed: \(error)") }
            output.fulfill()
        })
        await fulfillment(of: [output], timeout: 5)
        try await waitUntil("output after rejected input") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__OUTPUT_AFTER_REJECTION")
        }
        XCTAssertEqual(session.runtimeConnectionIssue, .inputTooLarge)
        session.controller.sendProcessInput(bytes: Array("printf '\\n__INPUT_RECOVERED\\n'\n".utf8))
        try await waitUntil("successful write dismisses input issue") {
            session.runtimeConnectionIssue == nil &&
                session.controller.visibleScreenText().components(separatedBy: "\n").contains("__INPUT_RECOVERED")
        }
        XCTAssertNil(session.controller.runtimeInputErrorCode)
    }

    func testCancelledInputQueueCannotWritePendingBytes() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("cancelled input viewer") { session.controller.runtimeHandle?.connected == true }
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        let before = try await prepare(handle)
        let queue = TerminalRuntimeInputQueue(handle: handle, approve: { _, _, _, _ in XCTFail("Cancelled input reached approval"); return true },
            committed: { _, _, _ in XCTFail("Cancelled bytes were written") }, failed: { _ in })
        let cancelled = expectation(description: "Cancelled callback exactly once")
        cancelled.assertForOverFulfill = true
        XCTAssertTrue(queue.enqueue(Array("printf '__CANCELLED_QUEUE'\n".utf8), source: .human, owner: nil) { result in
            if case .failure(TerminalRuntimeConnectionError.cancelled) = result {} else { XCTFail("Missing cancellation") }
            cancelled.fulfill()
        })
        queue.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        let after = try await prepare(handle)
        XCTAssertEqual(after.session.nextInputSequence, before.session.nextInputSequence)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__CANCELLED_QUEUE"))
    }

    func testRestoredAILeaseCreatesPrivateArchiveAndOmitsHiddenInput() async throws {
        let (root, helper) = try await startService()
        let original = TerminalSession(sequence: 1)
        let script = "stty -echo; printf '__PRIVATE_READY'; IFS= read -r input; printf '\\n__PRIVATE_DONE\\n'; sleep 2"
        attach(original, launch: .init(executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("private input program") { original.controller.visibleScreenText().contains("__PRIVATE_READY") }
        let acquired = expectation(description: "Lease before detach")
        original.changeAIControl(action: .acquireControl, owner: "resumed-owner", archiveDirectory: root.appendingPathComponent("first-archive")) { result in
            if case .failure(let error) = result { XCTFail("Acquire failed: \(error)") }; acquired.fulfill()
        }
        await fulfillment(of: [acquired], timeout: 5)
        let generation = try XCTUnwrap(original.runtimeInfo?.generation)
        original.detachForApplicationExit()
        let restored = TerminalSession(sequence: 2, id: original.id)
        restored.runtimeGenerationToRestore = generation
        attach(restored, launch: .init(executable: "/must-not-launch", directory: root.path), root: root, helper: helper)
        try await waitUntil("restored AI lease") { restored.controller.runtimeHandle?.connected == true && restored.aiLease?.owner == "resumed-owner" }
        let resumedDirectory = root.appendingPathComponent("resumed-archive")
        try restored.authorizeAIInput(owner: "resumed-owner", archiveDirectory: resumedDirectory)
        let sent = expectation(description: "Hidden input ACK after restore")
        restored.controller.sendToolInput(bytes: Array("fixture-hidden-input\n".utf8), owner: "resumed-owner") { result in
            if case .failure(let error) = result { XCTFail("Restored input failed: \(error)") }; sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 5)
        let files = try FileManager.default.contentsOfDirectory(at: resumedDirectory, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        let archive = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(archive.contains("viewer_reattached"))
        XCTAssertTrue(archive.contains("hidden_input_omitted"))
        XCTAssertFalse(archive.contains("fixture-hidden-input"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReplyPolicyDoesNotCreateAnArbitraryInputBypass() {
        for reply in ["\u{1b}[0n", "\u{1b}[12;34R", "\u{1b}[?62;1;2c", "\u{1b}]10;rgb:ffff/0000/abcd\u{1b}\\"] {
            XCTAssertTrue(TerminalRuntimeReplyPolicy.allows(Data(reply.utf8)))
        }
        for input in ["rm -rf .\n", "\u{1b}[0n\n", "\u{1b}]52;c;private\u{7}", "text", ""] {
            XCTAssertFalse(TerminalRuntimeReplyPolicy.allows(Data(input.utf8)))
        }
    }

    func testQuietViewerReceivesFirstOutputAfterWriteDeadline() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", "sleep 6; printf '__AFTER_IDLE'; sleep 1"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("quiet viewer subscription") { session.controller.runtimeHandle?.connected == true }
        let pid = try XCTUnwrap(session.runtimeInfo?.pid)
        try await waitUntil("first output after idle") { session.controller.visibleScreenText().contains("__AFTER_IDLE") }
        XCTAssertEqual(session.runtimeInfo?.pid, pid)
        XCTAssertTrue(session.controller.runtimeHandle?.connected == true)
        XCTAssertNil(session.runtimeConnectionIssue)
    }

    func testAppKitLengthPauseDoesNotDisconnectBoundedOutputSubscription() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        let fixture = "STDOUT.sync=true; puts '__PAUSE_READY__'; sleep 0.5; puts('x'*100_000); puts '__PAUSE_RECOVERED__'; sleep 20"
        attach(session, launch: .init(executable: "/usr/bin/ruby", arguments: ["-e", fixture],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("viewer before AppKit pause") {
            session.controller.runtimeHandle?.connected == true && session.controller.visibleScreenText().contains("__PAUSE_READY__")
        }
        let info = try XCTUnwrap(session.runtimeInfo)
        blockMainRunLoopForClipboardFixture()
        try await waitUntil("bounded backlog after AppKit pause") { session.controller.visibleScreenText().contains("__PAUSE_RECOVERED__") }
        XCTAssertEqual(session.runtimeInfo?.pid, info.pid)
        XCTAssertEqual(session.runtimeInfo?.generation, info.generation)
        XCTAssertTrue(session.controller.runtimeHandle?.connected == true)
        XCTAssertNil(session.controller.runtimeHandle?.lastError)
    }

    private func blockMainRunLoopForClipboardFixture() {
        // Deliberately exceeds the 5-second RPC deadline, while remaining well
        // within the output consumer budget. The child keeps writing meanwhile.
        Thread.sleep(forTimeInterval: 7)
    }

    func testToolBridgeWaitsForRuntimeControlAndInputResponses() async throws {
        let (root, helper) = try await startService()
        let defaultsName = "TerminalRuntimeBridge.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.toolBridgeWritesEnabled = true
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        workspace.preferences = preferences
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("tool bridge viewer subscription") { session.controller.runtimeHandle?.connected == true }
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        XCTAssertTrue(MuseTermKeychain.save("fixture-only-token", account: "runtime-fixture", serviceName: TerminalToolAccess.keychainServiceName))
        let toolRoot = root.appendingPathComponent("bridge")
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        defer { bridge.stop() }

        func request(_ action: String, owner: String = "owner-a", text: String? = nil, authorized: Bool = true) async throws -> [String: Any] {
            let id = UUID().uuidString
            var body: [String: Any] = ["id": id, "action": action, "tab": session.id.uuidString,
                "controlID": owner, "clientID": "runtime-fixture", "authToken": authorized ? "fixture-only-token" : "invalid-fixture-token"]
            body["text"] = text
            try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: body),
                to: toolRoot.appendingPathComponent("requests/\(id).json"))
            let result = toolRoot.appendingPathComponent("responses/\(id).json")
            try await waitUntil("tool response \(action)") { FileManager.default.fileExists(atPath: result.path) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        }

        let denied = try await request("takeover_tab", authorized: false)
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertNil(session.aiLease)
        let acquired = try await request("takeover_tab")
        XCTAssertEqual(acquired["ok"] as? Bool, true)
        XCTAssertEqual(session.runtimeInfo?.controlOwner, "owner-a")
        let wrongOwner = try await request("release_tab", owner: "owner-b")
        XCTAssertEqual(wrongOwner["ok"] as? Bool, false)
        XCTAssertEqual(session.runtimeInfo?.controlOwner, "owner-a")
        let sent = try await request("send_text", text: "printf '\\n__BRIDGE_EXECUTED\\n'\n")
        XCTAssertEqual(sent["ok"] as? Bool, true)
        try await waitUntil("tool input executed") { session.controller.visibleScreenText().components(separatedBy: "\n").contains("__BRIDGE_EXECUTED") }
        let released = try await request("release_tab")
        XCTAssertEqual(released["ok"] as? Bool, true)
        XCTAssertNil(session.runtimeInfo?.controlOwner)
        let stale = try await request("send_text", text: "printf '__STALE_BRIDGE_INPUT'\n")
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertFalse(session.controller.visibleScreenText().contains("__STALE_BRIDGE_INPUT"))
    }

    func testAgentToolBridgeAndNativeReportsShareBackendAuthority() async throws {
        let (root, helper) = try await startService()
        let defaultsName = "TerminalRuntimeAgentBridge.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.toolBridgeWritesEnabled = false // Status binding never grants terminal input.
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        workspace.preferences = preferences
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path), root: root, helper: helper)
        try await waitUntil("Agent tool runtime attached") { session.controller.runtimeHandle?.connected == true }
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        XCTAssertTrue(MuseTermKeychain.save("agent-fixture-token", account: "agent-runtime-fixture", serviceName: TerminalToolAccess.keychainServiceName))
        let toolRoot = root.appendingPathComponent("agent-bridge")
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        defer { bridge.stop() }
        func request(_ action: String, extra: [String: Any] = [:], paired: Bool = false, endpoint: URL? = nil) async throws -> [String: Any] {
            let id = UUID().uuidString
            var body: [String: Any] = ["id": id, "action": action, "tab": session.id.uuidString]
            body.merge(extra) { _, new in new }
            if paired { body["clientID"] = "agent-runtime-fixture"; body["authToken"] = "agent-fixture-token" }
            let directory = endpoint ?? toolRoot
            try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: body),
                to: directory.appendingPathComponent("requests/\(id).json"))
            let response = directory.appendingPathComponent("responses/\(id).json")
            try await waitUntil("Agent tool response \(action)") { FileManager.default.fileExists(atPath: response.path) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        }
        let denied = try await request("bind_agent", extra: ["agentKind": "willdeep"])
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertNil(session.agentStatus)
        let bound = try await request("bind_agent", extra: ["agentKind": "willdeep"], paired: true)
        XCTAssertEqual(bound["ok"] as? Bool, true)
        let grant = try XCTUnwrap(bound["agentGrant"] as? [String: Any])
        XCTAssertNil(session.aiLease)
        XCTAssertNil(session.runtimeInfo?.controlOwner)
        var report = grant
        report["sequence"] = 1; report["activity"] = "blocked"; report["blockReason"] = "approval"
        let reported = try await request("report_agent_state", extra: ["agentReport": report])
        XCTAssertEqual(reported["ok"] as? Bool, true)
        XCTAssertEqual((reported["agent"] as? [String: Any])?["instanceID"] as? String, grant["instanceID"] as? String)
        try await waitUntil("one authoritative pending item") { workspace.sessionRegistry.attention.activeItems.count == 1 }
        let backend = try TerminalRuntimeConnection(root: root)
        defer { backend.close() }
        let actual = try XCTUnwrap(backend.request(.init(action: .list)).sessions?.first)
        XCTAssertEqual(actual.agent?.instanceID.uuidString, grant["instanceID"] as? String)
        XCTAssertEqual(actual.agent?.activity, .blocked)
        var invalid = report
        invalid["sequence"] = 2; invalid["token"] = "wrong-fixture-status-token"
        let rejected = try await request("report_agent_state", extra: ["agentReport": invalid])
        XCTAssertEqual(rejected["error"] as? String, TerminalAgentReportError.invalidCapability.rawValue)
        XCTAssertTrue(session.controller.runtimeHandle?.connected == true)
        // The same grant also works at WillDeep's status-only native endpoint.
        report["sequence"] = 2; report["activity"] = "working"; report["blockReason"] = nil
        let native = try await request("report_agent_state", extra: ["agentReport": report], endpoint: root.appendingPathComponent("native-tools"))
        XCTAssertEqual(native["ok"] as? Bool, true)
        let fresh = try await request("get_agent_state")
        XCTAssertEqual((fresh["agent"] as? [String: Any])?["activity"] as? String, "working")
        XCTAssertNil(fresh["agentGrant"])
        let stale = try await request("report_agent_state", extra: ["agentReport": report])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertTrue(session.controller.runtimeHandle?.connected == true)
        try await waitUntil("resolved approval reflected from same backend") { workspace.sessionRegistry.attention.activeItems.isEmpty }
        let replacement = try await request("bind_agent", extra: ["agentKind": "codex"], paired: true)
        XCTAssertEqual(replacement["ok"] as? Bool, true)
        report["sequence"] = 3
        let late = try await request("report_agent_state", extra: ["agentReport": report])
        XCTAssertEqual(late["ok"] as? Bool, false)
        XCTAssertEqual(session.agentStatus?.kind, .codex)
        XCTAssertNil(session.runtimeInfo?.controlOwner)
        var read = TerminalRuntimeRequest(action: .readEvents)
        read.eventAfter = .init(appEpoch: try XCTUnwrap(backend.request(.init(action: .list)).serviceEpoch), sequence: 0)
        let events = try backend.request(read)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(try XCTUnwrap(grant["token"] as? String)))
        // Exercise the actual generated CLI with both UI request processing and
        // its viewer stopped. A backend grant must keep reporting independently.
        var binding = try XCTUnwrap(replacement["agentGrant"] as? [String: Any])
        binding["sequence"] = 0; binding["tab"] = session.id.uuidString
        binding["reportRoot"] = try XCTUnwrap(replacement["agentReportRoot"] as? String)
        let bindingFile = root.appendingPathComponent("private-cli-binding.json")
        try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: binding), to: bindingFile)
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let script = root.appendingPathComponent("direct-agent-report.rb")
        try (definitions + "\nputs JSON.generate(report_agent_binding({\"bindingFile\" => ARGV.fetch(0), \"activity\" => \"working\"}))\n")
            .write(to: script, atomically: true, encoding: .utf8)
        bridge.stop()
        session.controller.detachRuntimeViewer()
        let cli = Process()
        cli.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        cli.arguments = [script.path, bindingFile.path]
        cli.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe(), errors = Pipe()
        cli.standardOutput = output; cli.standardError = errors
        try cli.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        cli.waitUntilExit()
        XCTAssertEqual(cli.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((result["agent"] as? [String: Any])?["activity"] as? String, "working")
        XCTAssertTrue((result["agent"] as? [String: Any])?["updatedAt"] is String)
        let final = try XCTUnwrap(backend.request(.init(action: .list)).sessions?.first)
        XCTAssertEqual(final.agent?.kind, .codex)
        XCTAssertEqual(final.agent?.activity, .working)
        XCTAssertNil(final.controlOwner)
    }

    func testLateViewerPacketCannotUndoAcknowledgedAgentInboxVersion() throws {
        let events = TerminalSessionEventStore()
        let store = TerminalAttentionStore(events: events)
        let tab = UUID()
        var item = TerminalAttentionItem(id: UUID(), tabID: tab, instanceID: UUID(), runID: UUID(),
            kind: .approval, createdAt: Date(), createdSequence: 1, source: .integration, confidence: .high)
        store.adoptAgentItems([item], tabID: tab, cursor: .init(appEpoch: events.appEpoch, sequence: 1))
        var requested: (UUID, Int)?
        store.externalAcknowledgement[tab] = { id, version in requested = (id, version); return true }
        try store.markRead(id: item.id, version: item.version)
        XCTAssertEqual(requested?.0, item.id)
        XCTAssertNil(store.activeItems.first?.readAt, "Read state waits for the service ACK")
        let stale = item
        item.version += 1; item.readAt = Date()
        store.adoptAgentItems([item], tabID: tab, cursor: .init(appEpoch: events.appEpoch, sequence: 3))
        store.adoptAgentItems([stale], tabID: tab, cursor: .init(appEpoch: events.appEpoch, sequence: 2))
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertNotNil(store.activeItems.first?.readAt)
        XCTAssertFalse(store.hasUnread(tabID: tab))
    }

    private struct OfflineEventFixture {
        let root: URL
        let home: URL
        let toolRoot: URL
        let session: TerminalSession
        let bridge: TerminalToolBridge
        let grant: TerminalAgentGrant
        let cursor: TerminalEventCursor
    }

    private func offlineEventFixture() async throws -> OfflineEventFixture {
        let (root, helper) = try await startService()
        let home = root.appendingPathComponent("cli-home")
        let toolRoot = home.appendingPathComponent("Library/Application Support/MuseTerm/Tools")
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path), root: root, helper: helper)
        try await waitUntil("backend event fixture ready") {
            session.controller.runtimeHandle?.connected == true && session.controller.visibleScreenText().contains("__MODE_READY")
        }
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let info = try XCTUnwrap(session.runtimeInfo)
        var bind = TerminalRuntimeRequest(action: .bindAgent)
        bind.sessionID = session.id; bind.generation = info.generation; bind.agentKind = .willdeep
        let grant = try XCTUnwrap(connection.request(bind).agentGrant)
        var report = TerminalRuntimeRequest(action: .reportAgent)
        report.sessionID = session.id; report.generation = info.generation
        report.agentReport = .init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token, sequence: 1, activity: .working)
        _ = try connection.request(report)
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        let metadataPath = toolRoot.appendingPathComponent("runtime.json")
        try await waitUntil("UI publishes actual service source") {
            guard let data = try? Data(contentsOf: metadataPath), let metadata = try? JSONDecoder().decode(TerminalToolRuntime.self, from: data) else { return false }
            return metadata.backend?.root == root.appendingPathComponent("native-tools").path
        }
        let metadata = try JSONDecoder().decode(TerminalToolRuntime.self, from: Data(contentsOf: metadataPath))
        let cursor = try XCTUnwrap(metadata.backend?.cursor)
        XCTAssertNotEqual(metadata.appEpoch, cursor.appEpoch)
        bridge.stop()
        session.controller.detachRuntimeViewer()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataPath)) as? [String: Any])
        let newUIEpoch = UUID().uuidString
        fields["pid"] = Int32.max
        fields["appEpoch"] = newUIEpoch
        fields["cursor"] = ["appEpoch": newUIEpoch, "sequence": 0]
        try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: fields), to: metadataPath)
        return .init(root: root, home: home, toolRoot: toolRoot, session: session, bridge: bridge, grant: grant, cursor: cursor)
    }

    private func eventCLI(_ fixture: OfflineEventFixture, body: String) throws -> (Process, Pipe, Pipe, Pipe) {
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let path = fixture.root.appendingPathComponent("event-cli-\(UUID()).rb")
        try (definitions + "\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [path.path]
        process.environment = ["HOME": fixture.home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        return (process, input, output, errors)
    }

    private func backendWaitCount(_ root: URL) throws -> Int {
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        return try XCTUnwrap(connection.request(.init(action: .diagnostics)).pendingWaits)
    }

    func testGeneratedCLIReadsAndWaitsWithUIProcessingStopped() async throws {
        let fixture = try await offlineEventFixture()
        let tab = fixture.session.id.uuidString, grant = fixture.grant
        let body = """
        baseline = agent_request("read_session_events", {})
        status = agent_request("get_agent_state", {"tab" => "\(tab)"})
        spec = {"condition" => "agentState", "after" => baseline.fetch("eventBatch").fetch("nextCursor"),
          "tabID" => "\(tab)", "instanceID" => "\(grant.instanceID)", "runID" => "\(grant.runID)", "activity" => "blocked", "timeoutSeconds" => 5}
        result = wait_tool({"spec" => spec})
        puts JSON.generate({"baseline" => baseline, "status" => status, "wait" => result})
        """
        let (cli, _, output, errors) = try eventCLI(fixture, body: body)
        defer { if cli.isRunning { cli.terminate(); cli.waitUntilExit() } }
        try await waitUntil("generated CLI installed service waiter") { (try? self.backendWaitCount(fixture.root)) == 1 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.toolRoot.appendingPathComponent("requests").path).count, 0)
        let connection = try TerminalRuntimeConnection(root: fixture.root)
        defer { connection.close() }
        var report = TerminalRuntimeRequest(action: .reportAgent)
        report.sessionID = fixture.session.id; report.generation = fixture.session.runtimeInfo?.generation
        report.agentReport = .init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token, sequence: 2,
            activity: .blocked, blockReason: .approval)
        _ = try connection.request(report)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        cli.waitUntilExit()
        XCTAssertEqual(cli.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let waited = try XCTUnwrap((result["wait"] as? [String: Any])?["waitResult"] as? [String: Any])
        XCTAssertEqual(waited["outcome"] as? String, "matched")
        XCTAssertEqual((waited["agent"] as? [String: Any])?["instanceID"] as? String, grant.instanceID.uuidString)
        XCTAssertTrue((waited["agent"] as? [String: Any])?["updatedAt"] is String)
        XCTAssertEqual((waited["cursor"] as? [String: Any])?["appEpoch"] as? String, fixture.cursor.appEpoch.uuidString)
        XCTAssertNil(fixture.session.runtimeInfo?.controlOwner)
        XCTAssertEqual(try backendWaitCount(fixture.root), 0)
    }

    func testLiveViewerAndBackendShareCommandIdentity() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path), root: root, helper: helper)
        try await waitUntil("command viewer ready") { session.controller.visibleScreenText().contains("__MODE_READY") }
        // Simulate the provisional input record; the actual shell marker must replace its ID, not add a duplicate.
        session.observeProcessInput(data: Array("echo ok\n".utf8), echoEnabled: true, historySnapshot: "")
        let provisional = try XCTUnwrap(session.commandBlocks.last?.id)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        func input(_ line: String) throws {
            let info = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
            var request = TerminalRuntimeRequest(action: .input)
            request.sessionID = info.id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
            request.source = .human; request.inputSequence = info.nextInputSequence
            request.data = Data((line + "\n").utf8)
            _ = try connection.request(request)
        }
        try input("printf '\\033]777;MuseTerm;start=6563686f206f6b\\007'")
        try await waitUntil("same live marker identity") {
            guard let command = session.runtimeInfo?.commands?.last else { return false }
            return session.commandBlocks.last?.id == command.id
        }
        let command = try XCTUnwrap(session.runtimeInfo?.commands?.last)
        XCTAssertNotEqual(command.id, provisional)
        XCTAssertEqual(session.commandBlocks.filter { $0.command == "echo ok" }.count, 1)
        try input("printf '\\033]777;MuseTerm;end=0\\007'")
        try await waitUntil("both authorities complete same command") {
            session.runtimeInfo?.commands?.last?.state == .succeeded && session.commandBlocks.last?.endedAt != nil
        }
        XCTAssertEqual(session.commandBlocks.last?.id, command.id)
        XCTAssertEqual(session.commandBlocks.last?.exitCode, 0)
    }

    func testGeneratedCLIWaitsForExactBackendCommandWithoutUI() async throws {
        let fixture = try await offlineEventFixture()
        let connection = try TerminalRuntimeConnection(root: fixture.root)
        defer { connection.close() }
        func input(_ line: String) throws {
            let info = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
            var request = TerminalRuntimeRequest(action: .input)
            request.sessionID = info.id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
            request.source = .human; request.inputSequence = info.nextInputSequence
            request.data = Data((line + "\n").utf8)
            _ = try connection.request(request)
        }
        try input("printf '\\033]777;MuseTerm;start=6563686f206f6b\\007'")
        try await waitUntil("backend command started without viewer") {
            (try? connection.request(.init(action: .list)).sessions?.first?.commands?.last?.state) == .running
        }
        let command = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first?.commands?.last)
        let body = """
        baseline = agent_request("read_session_events", {})
        spec = {"condition" => "commandFinished", "after" => baseline.fetch("eventBatch").fetch("nextCursor"),
          "tabID" => "\(fixture.session.id)", "commandID" => "\(command.id)", "timeoutSeconds" => 5}
        puts JSON.generate(wait_tool({"spec" => spec}))
        """
        let (cli, _, output, errors) = try eventCLI(fixture, body: body)
        defer { if cli.isRunning { cli.terminate(); cli.waitUntilExit() } }
        try await waitUntil("generated CLI command waiter") { (try? self.backendWaitCount(fixture.root)) == 1 }
        XCTAssertTrue(cli.isRunning)
        try input("printf '\\033]777;MuseTerm;end=3\\007'")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        cli.waitUntilExit()
        XCTAssertEqual(cli.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(response["waitResult"] as? [String: Any])
        XCTAssertEqual(result["outcome"] as? String, "matched")
        XCTAssertEqual(result["commandID"] as? String, command.id.uuidString)
        XCTAssertEqual(result["commandState"] as? String, "failed")
        // A shell command ending must not terminate the independent native WillDeep task binding.
        XCTAssertEqual(try connection.request(.init(action: .list)).sessions?.first?.agent?.instanceID, fixture.grant.instanceID)
        XCTAssertEqual(try connection.request(.init(action: .list)).sessions?.first?.agent?.activity, .working)
    }

    private func readMCPLine(_ pipe: Pipe) throws -> [String: Any] {
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, 5_000) > 0 else { throw TerminalRuntimeConnectionError.timedOut }
        var bytes = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            bytes.append(byte)
            guard bytes.count <= TerminalRuntimeLimits.maximumClientQueueBytes else { throw TerminalRuntimeConnectionError.frameTooLarge }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private final class ReminderReporter: TerminalAttentionReporting {
        func terminalSession(_ session: TerminalSession, didProduceAttentionEvent event: TerminalAttentionEventKind) {
            _ = session.attentionStore?.recordTerminal(event, session: session, input: .init(event: event,
                appIsActive: false, tabIsSelected: false, notificationsEnabled: false, showInactiveTabBadges: true,
                notifyBells: true, notifyCommandFailures: true, notifyLongCommandCompletion: true, notifyProcessExits: true,
                longCommandThresholdSeconds: 0, failureMinimumDurationSeconds: 0))
        }
    }

    private func rawReminderInput(_ connection: TerminalRuntimeConnection, _ line: String) throws {
        let info = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
        var request = TerminalRuntimeRequest(action: .input)
        request.sessionID = info.id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
        request.source = .human; request.inputSequence = info.nextInputSequence; request.data = Data((line + "\n").utf8)
        _ = try connection.request(request)
    }

    func testUnconsumedPTYFrameDoesNotAdvanceRenderedCursor() async throws {
        let (root, helper) = try await startService()
        let handle = TerminalRuntimeSessionHandle(id: UUID(), root: root, executable: helper)
        defer { handle.closeTerminal() }
        var held: (TerminalRuntimeResponse, () -> Void)?
        handle.onOutput = { response, _, completion in
            if response.data?.isEmpty == false { held = (response, completion) }
            else { completion() }
        }
        handle.start(.init(executable: "/bin/sh", arguments: ["-c", "printf '__HELD_FRAME\\n'; sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path))
        try await waitUntil("actual PTY frame held by consumer") { held != nil }
        let frame = try XCTUnwrap(held)
        let cursor = try XCTUnwrap(frame.0.cursor)
        XCTAssertGreaterThan(cursor.offset, handle.renderedCursor?.offset ?? 0)
        frame.1()
        XCTAssertEqual(handle.renderedCursor, cursor)
    }

    func testContinuousRenderedOutputCheckpointsAndRestoresWithoutExitSave() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        var lifecycle: TerminalRuntimeWorkspaceLifecycle? = .init(root: root, enabled: true)
        lifecycle?.attach(workspace)
        let session = try XCTUnwrap(workspace.selectedTab)
        let launch = TerminalRuntimeLaunch(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path)
        attach(session, launch: launch, root: root, helper: helper)
        let store = TerminalRuntimeWorkspaceStore(root: root)
        func savedCursor() -> TerminalRuntimeOutputCursor? {
            (try? store.load(workspace.runtimeWorkspaceID))?.snapshot.tabs.first?.runtimeRenderedCursor
        }
        try await waitUntil("initial rendered cursor is saved") {
            session.controller.visibleScreenText().contains("__MODE_READY") && savedCursor() != nil
        }
        let baseline = try XCTUnwrap(savedCursor())
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        // The loop cannot finish until the test writes its private stop file;
        // checkpoint assertions therefore prove progress during continuous output.
        try rawReminderInput(connection,
            "while [ ! -f '\(root.path)/stop-checkpoint' ]; do printf '__CP_TICK\\n'; sleep 0.02; done; printf '__CP_DONE\\n'")
        try await waitUntil("first checkpoint advances while stream continues") { (savedCursor()?.offset ?? 0) > baseline.offset }
        let first = try XCTUnwrap(savedCursor())
        try await waitUntil("second checkpoint not starved by continuous rendering") { (savedCursor()?.offset ?? 0) > first.offset }
        try Data().write(to: root.appendingPathComponent("stop-checkpoint"), options: .atomic)
        try await waitUntil("stream finishes only after explicit stop") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__CP_DONE")
        }
        try rawReminderInput(connection, "printf '\\007__CP_BELL\\n'")
        try await waitUntil("bell frame rendered and its cursor saved") {
            session.controller.visibleScreenText().components(separatedBy: "\n").contains("__CP_BELL")
                && savedCursor() == session.runtimeRenderedCursor
        }
        let checkpoint = try XCTUnwrap(savedCursor()), original = try XCTUnwrap(session.runtimeInfo)
        let originalItem = try XCTUnwrap(connection.request(.init(action: .listAttention)).attention?.first)
        session.controller.detachRuntimeViewer()
        lifecycle = nil // Deliberately no prepareForExit or explicit final persist.
        try rawReminderInput(connection, "printf '\\007__CP_OFFLINE_BELL\\n'")
        let reopened = TerminalRuntimeWorkspaceLifecycle(root: root, enabled: true)
        let restoredWorkspace = reopened.makeWorkspace(automaticallyStartProcesses: false)
        try await waitUntil("record recovery discovery finishes") { !restoredWorkspace.runtimeDiscoveryInProgress }
        let restored = try XCTUnwrap(restoredWorkspace.sessionRegistry.sessions[session.id])
        XCTAssertEqual(restored.runtimeRenderedCursorToRestore, checkpoint)
        var bells = 0
        let terminal = try XCTUnwrap(restored.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        terminal.onTerminalBell = { bells += 1 }
        attach(restored, launch: launch, root: root, helper: helper) { XCTFail("Recovery must not run startup commands") }
        try await waitUntil("checkpoint replay and offline suffix are rendered") {
            restored.controller.visibleScreenText().components(separatedBy: "\n").contains("__CP_OFFLINE_BELL")
        }
        XCTAssertEqual(restored.runtimeInfo?.pid, original.pid)
        XCTAssertEqual(restored.runtimeInfo?.generation, original.generation)
        XCTAssertEqual(bells, 1)
        let currentItem = try XCTUnwrap(connection.request(.init(action: .listAttention)).attention?.first)
        XCTAssertEqual(currentItem.id, originalItem.id)
        XCTAssertEqual(currentItem.terminal?.occurrences, 2)
        XCTAssertEqual(restoredWorkspace.sessionRegistry.attention.activeItems.count, 1)
    }

    func testProjectToolProtectsLivePTYAndCloseOnlyRequestsUntilBackendConfirms() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path), root: root, helper: helper)
        try await waitUntil("live project fixture") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let pid = try XCTUnwrap(session.runtimeInfo?.pid)
        func close(terminate: Bool) throws -> TerminalToolResponse {
            let body: [String: Any] = ["id": UUID().uuidString, "action": "project_layout",
                "projectRequest": ["operation": "closeTerminal", "terminalID": session.id.uuidString, "terminateRunning": terminate,
                    "uiEpoch": workspace.sessionRegistry.events.appEpoch.uuidString,
                    "deadlineMonotonic": TerminalProjectToolService.requestMonotonicTime() + 5]]
            let request = try JSONDecoder().decode(TerminalToolRequest.self, from: JSONSerialization.data(withJSONObject: body))
            return TerminalProjectToolService.perform(request, workspace: workspace, snapshotSequence: 1, authorized: { true })
        }
        XCTAssertEqual(try close(terminate: false).error, "terminate_running_required")
        XCTAssertEqual(try connection.request(.init(action: .list)).sessions?.first?.pid, pid)
        let closed = try close(terminate: true)
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(closed.projectResult?.processClosure, "requested")
        try await waitUntil("explicit backend close acknowledged") {
            (try? connection.request(.init(action: .list)).sessions?.isEmpty) == true
        }
        XCTAssertFalse(workspace.projectLayout.terminalIDs.contains(session.id))
    }

    func testUnattachedRuntimeKeepsRequestedPTYSizeUntilRealViewMounts() async throws {
        let (root, helper) = try await startService()
        let session = TerminalSession(sequence: 1)
        viewers.append(session.controller)
        session.controller.startRuntime(.init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path,
            columns: TerminalRuntimeLimits.defaultColumns, rows: TerminalRuntimeLimits.defaultRows), root: root, executable: helper, ready: {})
        try await waitUntil("background runtime without view window") { session.controller.visibleScreenText().contains("__MODE_READY") }
        XCTAssertNil(session.controller.container.window)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let info = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
        XCTAssertEqual(info.columns, TerminalRuntimeLimits.defaultColumns)
        XCTAssertEqual(info.rows, TerminalRuntimeLimits.defaultRows)
    }

    func testProjectMoveKeepsActualPTYAndNativeApprovalIdentity() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        attach(session, launch: .init(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path), root: root, helper: helper)
        try await waitUntil("native move fixture") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let original = try XCTUnwrap(session.runtimeInfo)
        var bind = TerminalRuntimeRequest(action: .bindAgent)
        bind.sessionID = session.id; bind.generation = original.generation; bind.agentKind = .willdeep
        let grant = try XCTUnwrap(connection.request(bind).agentGrant)
        var report = TerminalRuntimeRequest(action: .reportAgent)
        report.sessionID = session.id; report.generation = original.generation
        report.agentReport = .init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
            sequence: 1, activity: .blocked, blockReason: .approval)
        _ = try connection.request(report)
        try await waitUntil("same backend approval visible") { workspace.sessionRegistry.attention.activeItems.count == 1 }
        let pending = try XCTUnwrap(workspace.sessionRegistry.attention.activeItems.first)
        func operation(_ fields: [String: Any]) throws -> TerminalToolResponse {
            var fields = fields
            fields["uiEpoch"] = workspace.sessionRegistry.events.appEpoch.uuidString
            fields["deadlineMonotonic"] = TerminalProjectToolService.requestMonotonicTime() + 5
            let body: [String: Any] = ["id": UUID().uuidString, "action": "project_layout", "projectRequest": fields]
            let request = try JSONDecoder().decode(TerminalToolRequest.self, from: JSONSerialization.data(withJSONObject: body))
            return TerminalProjectToolService.perform(request, workspace: workspace, snapshotSequence: 1, authorized: { true })
        }
        let destination = try XCTUnwrap(operation(["operation": "createProject", "name": "review"]).projectResult?.projectID)
        let tab = try XCTUnwrap(workspace.projectLayout.location(of: session.id)).1
        let source = try XCTUnwrap(workspace.projectLayout.location(of: session.id)).0
        let tabID = workspace.projectLayout.projects[source].tabs[tab].id
        XCTAssertTrue(try operation(["operation": "moveTab", "layoutTabID": tabID.uuidString, "projectID": destination.uuidString]).ok)
        let actual = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
        XCTAssertEqual(actual.pid, original.pid)
        XCTAssertEqual(actual.generation, original.generation)
        XCTAssertEqual(actual.agent?.instanceID, grant.instanceID)
        XCTAssertEqual(actual.agent?.activity, .blocked)
        let backendItem = try XCTUnwrap(connection.request(.init(action: .listAttention)).attention?.first)
        XCTAssertEqual(backendItem.id, pending.id)
        XCTAssertNil(backendItem.readAt)
        XCTAssertEqual(workspace.sessionRegistry.attention.activeItems.first?.id, pending.id)
        XCTAssertTrue(workspace.sessionRegistry.attention.hasUnread(tabID: session.id))
    }

    func testRuntimeBellInboxAndBadgeSurviveViewerReplayWithoutDuplicates() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let reporter = ReminderReporter()
        workspace.attentionReporter = reporter
        let session = try XCTUnwrap(workspace.selectedTab)
        let launch = TerminalRuntimeLaunch(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path)
        attach(session, launch: launch, root: root, helper: helper)
        try await waitUntil("reminder viewer ready") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        try rawReminderInput(connection, "printf '\\007\\007\\007'")
        let store = workspace.sessionRegistry.attention
        try await waitUntil("backend bell mirrored once") { store.activeItems.first?.terminal?.occurrences == 3 }
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertTrue(store.hasUnread(tabID: session.id))
        XCTAssertTrue(session.hasUnreadAttention)
        XCTAssertTrue(session.runtimeOwnsTerminalAttention)
        let item = try XCTUnwrap(store.activeItems.first)
        session.runtimeRenderedCursorToRestore = session.controller.runtimeHandle?.renderedCursor
        session.controller.detachRuntimeViewer()
        try rawReminderInput(connection, "printf '\\007\\007'")
        try await waitUntil("detached backend bell coalesced") {
            (try? connection.request(.init(action: .listAttention)).attention?.first?.terminal?.occurrences) == 5
        }
        session.controller.startRuntime(launch, root: root, executable: helper, ready: {})
        try await waitUntil("same reminder after replay") { store.activeItems.first?.terminal?.occurrences == 5 }
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertEqual(store.activeItems.first?.id, item.id)
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        let refreshed: TerminalRuntimeResponse = try await withCheckedThrowingContinuation { continuation in
            handle.acknowledge(id: item.id, version: item.version) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(refreshed.attention?.first?.terminal?.occurrences, 5, "A stale read refreshes current state instead of resolving the new version")
        let current = try XCTUnwrap(store.activeItems.first)
        try store.markRead(id: current.id, version: current.version)
        try await waitUntil("acknowledgement removes same inbox and badge") { store.activeItems.isEmpty && !session.hasUnreadAttention }
        XCTAssertTrue(try connection.request(.init(action: .listAttention)).attention?.isEmpty == true)
        handle.configureReminders(.init(bells: false))
        try await waitUntil("changed category acknowledged") { session.runtimeInfo?.reminderPolicy?.bells == false }
        try rawReminderInput(connection, "printf '\\007__DISABLED_BELL\\n'")
        try await waitUntil("disabled bell output rendered") { session.controller.visibleScreenText().contains("__DISABLED_BELL") }
        XCTAssertTrue(store.activeItems.isEmpty)
        XCTAssertFalse(session.hasUnreadAttention)
        withExtendedLifetime(reporter) {}
    }

    func testRepeatedAcknowledgementCompletesEveryCallerAndAllowsRetry() async throws {
        let (root, helper) = try await startService()
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let reporter = ReminderReporter()
        workspace.attentionReporter = reporter
        let session = try XCTUnwrap(workspace.selectedTab)
        let launch = TerminalRuntimeLaunch(executable: "/bin/sh", arguments: ["-c", Self.echoControlledShell],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path)
        attach(session, launch: launch, root: root, helper: helper)
        try await waitUntil("duplicate read fixture ready") { session.controller.visibleScreenText().contains("__MODE_READY") }
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        try rawReminderInput(connection, "printf '\\007'")
        let store = workspace.sessionRegistry.attention
        try await waitUntil("read fixture item") { store.activeItems.count == 1 }
        let original = try XCTUnwrap(store.activeItems.first)
        try rawReminderInput(connection, "printf '\\007'")
        try await waitUntil("new reminder version") { store.activeItems.first?.terminal?.occurrences == 2 }
        let current = try XCTUnwrap(store.activeItems.first)
        let handle = try XCTUnwrap(session.controller.runtimeHandle)
        var firstResults: [Result<TerminalRuntimeResponse, Error>] = []
        var duplicateResults: [Result<TerminalRuntimeResponse, Error>] = []
        handle.acknowledge(id: original.id, version: original.version) { firstResults.append($0) }
        handle.acknowledge(id: current.id, version: current.version) { duplicateResults.append($0) }
        XCTAssertEqual(duplicateResults.count, 1, "An in-flight duplicate must complete rather than disappear")
        if case .failure(TerminalRuntimeConnectionError.rejected(let code)) = duplicateResults.first {
            XCTAssertEqual(code, "attention_acknowledgement_pending")
        } else { XCTFail("Duplicate must explicitly report that no acknowledgement was sent") }
        try await waitUntil("first stale read refreshed") { firstResults.count == 1 }
        XCTAssertEqual(try firstResults[0].get().attention?.first?.version, current.version)
        XCTAssertEqual(try connection.request(.init(action: .listAttention)).attention?.first?.version, current.version)
        let acknowledged: TerminalRuntimeResponse = try await withCheckedThrowingContinuation { continuation in
            handle.acknowledge(id: current.id, version: current.version) { continuation.resume(with: $0) }
        }
        XCTAssertTrue(acknowledged.ok)
        try await waitUntil("retry removed item and badge") { store.activeItems.isEmpty && !session.hasUnreadAttention }
        XCTAssertEqual(firstResults.count, 1)
        XCTAssertEqual(duplicateResults.count, 1)
        try rawReminderInput(connection, "printf '\\007'")
        try await waitUntil("new item for duplicate UI read") { store.activeItems.count == 1 }
        let next = try XCTUnwrap(store.activeItems.first)
        try store.markRead(id: next.id, version: next.version)
        try store.markRead(id: next.id, version: next.version)
        try await waitUntil("duplicate UI read removed item") { store.activeItems.isEmpty }
        XCTAssertNil(session.runtimeConnectionIssue, "In-flight duplicate is not a disconnected backend")
        withExtendedLifetime(reporter) {}
    }

    func testAcknowledgementCompletesWhenHandleReleasedInFlight() async throws {
        let (root, helper) = try await startService()
        var handle: TerminalRuntimeSessionHandle? = .init(id: UUID(), root: root, executable: helper)
        handle?.onOutput = { _, _, consumed in consumed() }
        handle?.start(.init(executable: "/bin/sh", arguments: ["-c", "exec sleep 20"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path))
        try await waitUntil("release fixture ready") { handle?.connected == true }
        weak var released = handle
        var results: [Result<TerminalRuntimeResponse, Error>] = []
        handle?.acknowledge(id: UUID(), version: 1) { results.append($0) }
        handle = nil
        XCTAssertNil(released, "An acknowledgement must not retain the UI projection")
        try await waitUntil("released handle completion") { results.count == 1 }
        if case .failure(TerminalRuntimeConnectionError.unavailable) = results.first {} else {
            XCTFail("Released projection must report unavailable exactly once")
        }
        XCTAssertEqual(results.count, 1)
    }

    func testSwiftConnectorReadsAll64EscapedPathSessionsWithFullMetadata() async throws {
        let (root, _) = try await startService()
        var directory = root
        while directory.path.utf8.count + 111 < 1_000 {
            directory.appendPathComponent(String(repeating: "\u{01}", count: 110), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        var sessions: [TerminalRuntimeSessionInfo] = []
        defer {
            for session in sessions {
                var close = TerminalRuntimeRequest(action: .close)
                close.sessionID = session.id; close.generation = session.generation; close.controlEpoch = session.controlEpoch
                do { _ = try connection.request(close) } catch { XCTFail("Owned capacity fixture close failed") }
            }
        }
        let marker = "\u{1B}]777;MuseTerm;start=6563686f206361706163697479\u{07}\u{1B}]777;MuseTerm;end=0\u{07}"
        for _ in 0..<TerminalRuntimeLimits.maximumSessions {
            var create = TerminalRuntimeRequest(action: .create)
            create.launch = .init(executable: "/bin/sh",
                arguments: ["-c", "printf '%s' '\(String(repeating: marker, count: 8))'; exec sleep 120"],
                environment: ["PATH": "/usr/bin:/bin"], directory: directory.path)
            let info = try XCTUnwrap(connection.request(create).session)
            sessions.append(info)
            var bind = TerminalRuntimeRequest(action: .bindAgent)
            bind.sessionID = info.id; bind.generation = info.generation; bind.agentKind = .willdeep
            let grant = try XCTUnwrap(connection.request(bind).agentGrant)
            var report = TerminalRuntimeRequest(action: .reportAgent)
            report.sessionID = info.id; report.generation = info.generation
            report.agentReport = .init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
                sequence: 1, activity: .working, context: .init(sessionID: UUID(),
                    taskID: String(repeating: "/", count: 128), gateID: String(repeating: "/", count: 128)))
            _ = try connection.request(report)
        }
        var actual: [TerminalRuntimeSessionInfo] = []
        try await waitUntil("all 64 large metadata projections") {
            actual = (try? connection.request(.init(action: .list)).sessions) ?? []
            return actual.count == 64 && actual.allSatisfy { $0.commands?.count == 8 }
        }
        XCTAssertEqual(Set(actual.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertTrue(actual.allSatisfy { $0.directory == directory.path && $0.agent?.activity == .working && $0.running })
        XCTAssertGreaterThan(try JSONEncoder().encode(actual).count, 262_144,
            "Fixture must exceed the old response/queue budget through legal escaped metadata")
    }

    func testGeneratedCLIListsSameReminderWithUIStopped() async throws {
        let fixture = try await offlineEventFixture()
        let connection = try TerminalRuntimeConnection(root: fixture.root)
        defer { connection.close() }
        // The shared fixture starts a native working agent. Fresh semantic
        // agents suppress raw beeps; explicitly exercise the unknown fallback.
        var report = TerminalRuntimeRequest(action: .reportAgent)
        report.sessionID = fixture.session.id; report.generation = fixture.session.runtimeInfo?.generation
        report.agentReport = .init(instanceID: fixture.grant.instanceID, runID: fixture.grant.runID,
            token: fixture.grant.token, sequence: 2, activity: .unknown)
        _ = try connection.request(report)
        try rawReminderInput(connection, "printf '\\007'")
        try await waitUntil("offline reminder exists") {
            (try? connection.request(.init(action: .listAttention)).attention?.count) == 1
        }
        let item = try XCTUnwrap(connection.request(.init(action: .listAttention)).attention?.first)
        let body = "puts JSON.generate(attention_tool(\"list_attention\", {\"tab\" => \"\(fixture.session.id)\"}))"
        let (cli, _, output, errors) = try eventCLI(fixture, body: body)
        defer { if cli.isRunning { cli.terminate(); cli.waitUntilExit() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        cli.waitUntilExit()
        XCTAssertEqual(cli.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let listed = try XCTUnwrap(response["attention"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["id"] as? String, item.id.uuidString)
        XCTAssertTrue(listed.first?["createdAt"] is String)
    }

    func testGeneratedMCPBackendWaitCancellationAndEOFReleaseActualWaiters() async throws {
        let fixture = try await offlineEventFixture()
        let (mcp, input, output, _) = try eventCLI(fixture, body: "command_mcp")
        defer { if mcp.isRunning { mcp.terminate(); mcp.waitUntilExit() } }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let spec: [String: Any] = ["condition": "agentState", "after": ["appEpoch": fixture.cursor.appEpoch.uuidString, "sequence": fixture.cursor.sequence],
            "tabID": fixture.session.id.uuidString, "instanceID": fixture.grant.instanceID.uuidString,
            "runID": fixture.grant.runID.uuidString, "activity": "blocked", "timeoutSeconds": 30]
        func begin(_ id: Int) throws {
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "wait_session", "arguments": ["spec": spec]]])
        }
        try begin(1)
        try await waitUntil("MCP service wait active") { (try? self.backendWaitCount(fixture.root)) == 1 }
        try send(["jsonrpc": "2.0", "id": 2, "method": "ping"])
        XCTAssertEqual(try readMCPLine(output)["id"] as? Int, 2)
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]])
        try await waitUntil("MCP cancellation removed actual backend wait") { (try? self.backendWaitCount(fixture.root)) == 0 }
        try send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        XCTAssertEqual(try readMCPLine(output)["id"] as? Int, 3, "Cancelled request must not emit an MCP result")
        try begin(4)
        try await waitUntil("second MCP backend waiter") { (try? self.backendWaitCount(fixture.root)) == 1 }
        try input.fileHandleForWriting.close()
        try await waitUntil("MCP EOF exits") { !mcp.isRunning }
        try await waitUntil("MCP EOF removed actual service wait") { (try? self.backendWaitCount(fixture.root)) == 0 }
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertEqual(mcp.terminationStatus, 0)
    }
}
