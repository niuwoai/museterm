import AppKit
import Combine
import Darwin
import Foundation

enum TerminalLaunchConfiguration: Equatable {
    case localShell(startDirectory: String? = nil, profile: TerminalProfile? = nil)
    case ssh(SSHConnectionProfile)

    var connectionLabel: String? {
        switch self {
        case .localShell:
            return nil
        case .ssh(let profile):
            return profile.displayName
        }
    }

    var connectionSubtitle: String? {
        switch self {
        case .localShell:
            return nil
        case .ssh(let profile):
            let clean = profile.normalized
            if clean.jumpHosts.isEmpty {
                return clean.target
            }
            return L10n.format("ssh.tab.subtitle_with_jumps", clean.target, clean.jumpHosts.count)
        }
    }

    var environment: TerminalEnvironmentKind {
        switch self {
        case .localShell:
            return .local
        case .ssh(let profile):
            return profile.normalized.environment
        }
    }

    var safetyPolicy: SSHSafetyConfirmationPolicy {
        switch self {
        case .localShell:
            return .inherit
        case .ssh(let profile):
            return profile.normalized.safetyPolicy
        }
    }

    var localStartDirectory: String? {
        guard case .localShell(let startDirectory, _) = self else { return nil }
        return startDirectory
    }

    var localProfile: TerminalProfile? {
        guard case .localShell(_, let profile) = self else { return nil }
        return profile
    }
}

enum TerminalCommandCompletionSource: String, Codable, Equatable {
    case shellIntegration
    case processExit
    case userInterrupt
    case superseded
    case unknown

    var contextLabel: String {
        switch self {
        case .shellIntegration:
            return "shellIntegration"
        case .processExit:
            return "processExit"
        case .userInterrupt:
            return "userInterrupt"
        case .superseded:
            return "superseded"
        case .unknown:
            return "unknown"
        }
    }
}

enum TerminalCommandStartSource: String, Codable, Equatable {
    case userInput
    case shellIntegration
    case unknown

    var contextLabel: String {
        switch self {
        case .userInput:
            return "userInput"
        case .shellIntegration:
            return "shellIntegration"
        case .unknown:
            return "unknown"
        }
    }
}

enum TerminalCommandBoundaryConfidence: String, Codable, Equatable {
    case high
    case medium
    case low

    var contextLabel: String {
        rawValue
    }
}

enum TerminalCommandBoundaryReason: String, Codable, Equatable {
    case shellIntegrationStart = "shell_integration_start"
    case userInputStart = "user_input_start"
    case missingStartSource = "missing_start_source"
    case unknownStartSource = "unknown_start_source"
    case shellIntegrationCompletion = "shell_integration_completion"
    case processExitCompletion = "process_exit_completion"
    case userInterruptCompletion = "user_interrupt_completion"
    case supersededCompletion = "superseded_completion"
    case commandStillRunning = "command_still_running"
    case missingCompletionSource = "missing_completion_source"
    case unknownCompletionSource = "unknown_completion_source"

    var contextLabel: String {
        rawValue
    }
}

struct TerminalCommandBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var command: String
    var workingDirectory: String?
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var outputTail: String
    var outputCharacterCount: Int
    var outputSummary: TerminalOutputSummary?
    var isInteractive: Bool
    var commandStartSource: TerminalCommandStartSource?
    var completionSource: TerminalCommandCompletionSource?
    var executionContext: TerminalExecutionContext? = nil

    var durationMilliseconds: Int? {
        guard let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt) * 1000))
    }

    var commandBoundaryConfidence: TerminalCommandBoundaryConfidence {
        switch (commandStartSource, completionSource) {
        case (.shellIntegration?, .shellIntegration?):
            return .high
        case (.shellIntegration?, .processExit?),
             (.shellIntegration?, .userInterrupt?),
             (.userInput?, .shellIntegration?):
            return .medium
        default:
            return .low
        }
    }

    var commandLifecycleState: TerminalCommandLifecycleState {
        if endedAt == nil {
            return .running
        }
        if completionSource == .userInterrupt {
            return .interrupted
        }
        if completionSource == .superseded {
            return .superseded
        }
        if let exitCode {
            return exitCode == 0 ? .succeeded : .failed
        }
        return .completedUnknownStatus
    }

    var commandRiskProfile: TerminalCommandRiskProfile {
        TerminalCommandRiskAnalyzer.profile(for: command)
    }

    var commandBoundaryReasons: [TerminalCommandBoundaryReason] {
        var reasons: [TerminalCommandBoundaryReason] = []

        switch commandStartSource {
        case .shellIntegration:
            reasons.append(.shellIntegrationStart)
        case .userInput:
            reasons.append(.userInputStart)
        case .unknown:
            reasons.append(.unknownStartSource)
        case nil:
            reasons.append(.missingStartSource)
        }

        if endedAt == nil, completionSource == nil {
            reasons.append(.commandStillRunning)
            return reasons
        }

        switch completionSource {
        case .shellIntegration:
            reasons.append(.shellIntegrationCompletion)
        case .processExit:
            reasons.append(.processExitCompletion)
        case .userInterrupt:
            reasons.append(.userInterruptCompletion)
        case .superseded:
            reasons.append(.supersededCompletion)
        case .unknown:
            reasons.append(.unknownCompletionSource)
        case nil:
            reasons.append(.missingCompletionSource)
        }

        return reasons
    }

    var statusText: String {
        if let exitCode {
            return exitCode == 0 ? "ok" : "exit(\(exitCode))"
        }
        return endedAt == nil ? "running" : "done"
    }

    var searchableText: String {
        [
            command,
            workingDirectory ?? "",
            outputTail,
            outputSummary?.searchableText ?? "",
            statusText,
            commandLifecycleState.contextLabel,
            commandRiskProfile.level.contextLabel,
            commandRiskProfile.reasons.map(\.contextLabel).joined(separator: " "),
            commandStartSource?.contextLabel ?? "",
            completionSource?.contextLabel ?? "",
            commandBoundaryConfidence.contextLabel,
            commandBoundaryReasons.map(\.contextLabel).joined(separator: " ")
        ].joined(separator: "\n")
    }

    var aiContextText: String {
        aiContextText(includeOutput: true)
    }

    func aiContextText(includeOutput: Bool) -> String {
        var lines: [String] = []
        lines.append("Command: \(command)")
        if let workingDirectory {
            lines.append("Directory: \(workingDirectory)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines.append("Started: \(formatter.string(from: startedAt))")
        if let commandStartSource {
            lines.append("Command source: \(commandStartSource.contextLabel)")
        }
        if let endedAt {
            lines.append("Ended: \(formatter.string(from: endedAt))")
        }
        if let durationMilliseconds {
            lines.append("Duration: \(durationMilliseconds) ms")
        }
        lines.append("Status: \(statusText)")
        lines.append("Lifecycle state: \(commandLifecycleState.contextLabel)")
        lines.append("Risk level: \(commandRiskProfile.level.contextLabel)")
        lines.append("Risk reasons: \(commandRiskProfile.reasons.map(\.contextLabel).joined(separator: ", "))")
        if let completionSource {
            lines.append("Completion source: \(completionSource.contextLabel)")
        }
        lines.append("Command boundary confidence: \(commandBoundaryConfidence.contextLabel)")
        lines.append("Command boundary reasons: \(commandBoundaryReasons.map(\.contextLabel).joined(separator: ", "))")
        if let outputSummary, !outputSummary.isEmpty {
            lines.append("")
            lines.append("Output summary:")
            lines.append(outputSummary.aiContextText)
        }
        if includeOutput, !outputTail.isEmpty {
            lines.append("")
            lines.append("Output tail:")
            lines.append(outputTail)
        }
        return lines.joined(separator: "\n")
    }
}

final class TerminalSession: ObservableObject, Identifiable {
    enum State {
        case running
        case exited(Int32?)
    }

    let id: UUID
    let sequence: Int
    let createdAt = Date()
    let launchConfiguration: TerminalLaunchConfiguration

    @Published var title: String
    @Published var currentDirectory: String?
    @Published private(set) var shellName: String?
    @Published var state: State = .running {
        didSet {
            if case .exited = state {
                if !runtimeOwnsAgent { updateAgent { $0.exit(now: Date()) } }
                if case .running = oldValue { eventStore?.publish(tabID: id, kind: .processExited) }
            }
        }
    }
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var isPlayingShortcut = false
    @Published private(set) var fileTransferStatus: TerminalFileTransferStatus?
    @Published private(set) var sessionTunnelStatus: SessionTunnelStatus?
    @Published private(set) var commandBlocks: [TerminalCommandBlock] = []
    @Published private(set) var historySearchSnapshot = ""
    @Published private(set) var hasUnreadAttention = false
    private(set) var processRunID = UUID()
    weak var attentionStore: TerminalAttentionStore?
    let nativeAgentContext = TerminalNativeAgentContext()
    @Published private(set) var runtimeInfo: TerminalRuntimeSessionInfo?
    @Published var runtimeConnectionIssue: TerminalRuntimePresentationIssue?
    @Published var runtimeSessionWasReopened = false
    /// Only ordinary local shells restored from a known workspace may be opened
    /// anew after the service confirms the saved process no longer exists.
    var runtimeRestoresLocalShell = false
    var onNewLocalTerminal: (() -> Void)?
    /// Hidden only for the current app run after a restored Runtime session fails to reconnect.
    /// It is intentionally not persisted so the next launch can retry recovery.
    @Published var runtimeRestoreHidden = false
    private(set) var runtimeOwnsAgent = false
    var runtimeOwnsTerminalAttention = false
    var runtimeGenerationToRestore: UUID?
    var runtimeAttachOnly = false
    var runtimeRecoveryRoot: URL?
    var runtimeRenderedCursorToRestore: TerminalRuntimeOutputCursor?
    var runtimeRenderedCursor: TerminalRuntimeOutputCursor? {
        (didCreateController ? controller.runtimeHandle?.renderedCursor : nil) ?? runtimeRenderedCursorToRestore
    }
    var runtimeRequiresExisting = false
    var runtimePendingCreationEpoch: UUID?
    var onRuntimeCreationChanged: (() throws -> Void)?
    var onRuntimeIdentityChanged: (() -> Void)?
    var onRuntimeOutputRendered: (() -> Void)?

    func applyRuntimeInfo(_ info: TerminalRuntimeSessionInfo) {
        guard info.id == id else { return }
        let identityChanged = runtimeInfo?.generation != info.generation
        if runtimeRenderedCursorToRestore?.generation != info.generation { runtimeRenderedCursorToRestore = nil }
        runtimeGenerationToRestore = info.generation
        runtimePendingCreationEpoch = nil
        runtimeInfo = info
        processRunID = info.generation
        applyRuntimeControl(info)
        if identityChanged { onRuntimeIdentityChanged?() }
        if info.agent != nil || runtimeOwnsAgent {
            runtimeOwnsAgent = true
            let previous = agentStatus
            agentStatus = info.agent
            if !TerminalAgentSnapshot.sameEvidence(previous, info.agent) {
                eventStore?.publish(tabID: id, kind: .agentChanged, agent: info.agent)
            }
        }
    }
    var onPaneFocus: (() -> Void)?
    @Published private(set) var executionContext: TerminalExecutionContext
    @Published private(set) var aiLease: TerminalAILease?
    @Published private(set) var agentStatus: TerminalAgentSnapshot?
    private var agentMonitor = TerminalAgentMonitor()
    weak var eventStore: TerminalSessionEventStore?
    var onSessionClosed: ((UUID) -> Void)?
    private var sessionWasClosed = false
    private(set) var lastOutputRevision = 0

    func recordOutputRevision(_ revision: Int) {
        lastOutputRevision = revision
        eventStore?.publish(tabID: id, kind: .outputChanged, revision: revision)
    }

    @discardableResult
    func updateAgent<T>(_ operation: (inout TerminalAgentMonitor) throws -> T) rethrows -> T {
        let previous = agentStatus
        let result = try operation(&agentMonitor)
        if agentStatus != agentMonitor.snapshot { agentStatus = agentMonitor.snapshot }
        if !TerminalAgentSnapshot.sameEvidence(previous, agentStatus) {
            eventStore?.publish(tabID: id, kind: .agentChanged, agent: agentStatus)
        }
        return result
    }

    func sampleAgentIfControllerExists() {
        if didCreateController, eventStore != nil { controller.sampleAgentForeground() }
    }
    private var aiArchive: TerminalAIArchive?
    private var aiExpiryTask: DispatchWorkItem?
    private(set) var aiRequiresTakeover = false
    /// Set when a fill took a lease of its own. The backend confirms the release
    /// after the write, and a subscription frame can put the lease back locally
    /// before that confirmation lands, so the next fill must replace it instead
    /// of writing under an owner the service has already dropped.
    private var assistantLeaseOwner: String?

    func takeAIControl(owner: String, now: Date = Date(), archiveDirectory: URL = TerminalAIArchive.directory) throws {
        guard runtimeInfo == nil, !didCreateController || controller.runtimeHandle == nil else { throw TerminalAIControlError.busy }
        expireAIControlIfNeeded(now: now)
        guard aiLease == nil || aiLease?.owner == owner else {
            throw TerminalAIControlError.owned
        }
        guard case .running = state else { throw TerminalToolError.processUnavailable }
        guard !isPlayingShortcut, sessionTunnelStatus?.occupiesTerminal != true,
              fileTransferStatus?.isActive != true else { throw TerminalAIControlError.busy }
        if aiArchive == nil { aiArchive = try TerminalAIArchive(tabID: id, directory: archiveDirectory) }
        aiRequiresTakeover = true
        aiLease = TerminalAILease(owner: owner, expiresAt: now.addingTimeInterval(TerminalAILease.duration))
        eventStore?.publish(tabID: id, kind: .controlChanged)
        scheduleAIExpiry()
    }

    func renewAIControl(owner: String, now: Date = Date()) throws {
        guard runtimeInfo == nil, !didCreateController || controller.runtimeHandle == nil else { throw TerminalAIControlError.busy }
        expireAIControlIfNeeded(now: now)
        guard aiLease?.owner == owner else { throw TerminalAIControlError.retake }
        aiLease?.expiresAt = now.addingTimeInterval(TerminalAILease.duration)
        scheduleAIExpiry()
    }

    /// The owner the runtime will accept for an AI write. A caller that already
    /// names one keeps it; the assistant panel does not, and a runtime-backed
    /// session rejects ownerless input, so the panel takes its own short lease.
    /// The returned flag says the lease belongs to this fill and must be given
    /// back once the write is acknowledged, so the keyboard is not left locked.
    func runtimeToolInputOwner(requested owner: String?, now: Date = Date()) throws -> (owner: String, releaseAfterWrite: Bool) {
        expireAIControlIfNeeded(now: now)
        if let aiLease, aiLease.owner != assistantLeaseOwner { return (aiLease.owner, false) }
        if let owner {
            // A lease owned by someone else was returned above. Reaching here
            // means there is no lease, or only the one a previous fill took and
            // is still releasing, which this write replaces.
            if runtimeInfo != nil {
                changeAIControl(action: .acquireControl, owner: owner) { [weak self] result in
                    if case .failure = result { self?.runtimeConnectionIssue = .inputRejected }
                }
            }
            return (owner, false)
        }
        let owner = "assistant-" + UUID().uuidString.lowercased()
        assistantLeaseOwner = owner
        // This lease exists only to let one fill through. It must not arm the
        // retake gate, or the next fill is rejected for lacking a takeover.
        aiRequiresTakeover = false
        if runtimeInfo != nil {
            changeAIControl(action: .acquireControl, owner: owner) { [weak self] result in
                if case .failure = result { self?.runtimeConnectionIssue = .inputRejected }
            }
        }
        return (owner, true)
    }

    func authorizeAIInput(owner: String?, archiveDirectory: URL = TerminalAIArchive.directory) throws {
        expireAIControlIfNeeded()
        if let aiLease {
            guard aiLease.owner == owner else { throw TerminalAIControlError.owned }
        } else if aiRequiresTakeover {
            throw TerminalAIControlError.retake
        }
        if runtimeInfo != nil, aiLease != nil, aiArchive == nil {
            let archive = try TerminalAIArchive(tabID: id, directory: archiveDirectory)
            try archive.event("viewer_reattached")
            aiArchive = archive
        }
    }

    func archiveAIInput(_ bytes: [UInt8], echoEnabled: Bool) throws {
        try aiArchive?.record(bytes, echoEnabled: echoEnabled)
    }

    func releaseAIControl(reason: String) {
        if runtimeInfo != nil, didCreateController, controller.runtimeHandle != nil,
           !["terminal_closed", "process_exited", "tab_closed"].contains(reason) {
            changeAIControl(action: .releaseControl, owner: nil) { [weak self] result in
                if case .failure = result { self?.runtimeConnectionIssue = .inputRejected }
            }
            return
        }
        finishAIControl(reason: reason)
    }

    private func finishAIControl(reason: String) {
        let hadLease = aiLease != nil
        aiExpiryTask?.cancel()
        aiExpiryTask = nil
        do {
            try aiArchive?.flush()
            try aiArchive?.event(reason)
        } catch {
            NSLog("MuseTerm AI archive could not be finalized: %@", error.localizedDescription)
        }
        aiArchive = nil
        aiLease = nil
        assistantLeaseOwner = nil
        if hadLease { eventStore?.publish(tabID: id, kind: .controlChanged) }
    }

    func expireAIControlIfNeeded(now: Date = Date()) {
        guard runtimeInfo == nil else { return } // The service owns lease expiry.
        if let aiLease, now >= aiLease.expiresAt { releaseAIControl(reason: "lease_expired") }
    }

    private func applyRuntimeControl(_ info: TerminalRuntimeSessionInfo) {
        aiExpiryTask?.cancel(); aiExpiryTask = nil
        if let owner = info.controlOwner, let expiresAt = info.controlExpiresAt {
            let previousOwner = aiLease?.owner
            aiLease = TerminalAILease(owner: owner, expiresAt: expiresAt)
            // A lease the fill took for itself is released once the write lands.
            // The subscription reports it before that release is confirmed, and
            // treating it as a takeover would make the next fill demand a retake.
            if owner != assistantLeaseOwner { aiRequiresTakeover = true }
            if previousOwner != owner { eventStore?.publish(tabID: id, kind: .controlChanged) }
        } else if aiLease != nil {
            finishAIControl(reason: "backend_released")
        }
    }

    func changeAIControl(action: TerminalRuntimeAction, owner: String?,
                         archiveDirectory: URL = TerminalAIArchive.directory,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard [.acquireControl, .renewControl, .releaseControl].contains(action) else { throw TerminalAIControlError.inputRejected }
            guard let runtimeInfo else {
                guard !didCreateController || controller.runtimeHandle == nil else { throw TerminalToolError.processUnavailable }
                if action == .acquireControl, let owner { try takeAIControl(owner: owner, archiveDirectory: archiveDirectory) }
                else if action == .renewControl, let owner { try renewAIControl(owner: owner) }
                else if action == .releaseControl { releaseAIControl(reason: "released") }
                else { throw TerminalAIControlError.retake }
                completion(.success(())); return
            }
            guard didCreateController, let handle = controller.runtimeHandle, handle.connected, runtimeInfo.running else {
                throw TerminalToolError.processUnavailable
            }
            guard !isPlayingShortcut, sessionTunnelStatus?.occupiesTerminal != true,
                  fileTransferStatus?.isActive != true else { throw TerminalAIControlError.busy }
            let archive = action == .acquireControl && aiArchive == nil
                ? try TerminalAIArchive(tabID: id, directory: archiveDirectory) : nil
            handle.control(action, owner: owner) { [weak self] result in
                switch result {
                case .success:
                    if let archive { self?.aiArchive = archive }
                    completion(.success(()))
                case .failure(let error): completion(.failure(error))
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func scheduleAIExpiry() {
        aiExpiryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.expireAIControlIfNeeded() }
        aiExpiryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalAILease.duration, execute: task)
    }

    private var didCreateController = false
    lazy var controller: TerminalHostController = {
        didCreateController = true
        return TerminalHostController(session: self)
    }()
    private var recorder: TerminalShortcutRecorder?
    private var pendingCommandBytes: [UInt8] = []
    private var activeCommandBlockID: UUID?
    private var activeCommandOutputStartIndex = 0
    private let maxCommandBlocks = 200
    private let maxCommandOutputTailCharacters = 12_000
    private let maxOutputSummaryScanCharacters = 65_536
    private let maxHistorySearchCharacters = 240_000
    private var latestReportedContext: TerminalShellReportedContext?
    private var didFinishStartupCommands = false
    private var pendingContextAction: PendingContextAction?
    weak var attentionReporter: TerminalAttentionReporting?
    var commandCompletionHandler: ((TerminalSession, TerminalCommandBlock) -> Void)?

    init(sequence: Int, launchConfiguration: TerminalLaunchConfiguration = .localShell(), id: UUID = UUID()) {
        self.id = id
        self.sequence = sequence
        self.launchConfiguration = launchConfiguration
        title = launchConfiguration.connectionLabel ?? L10n.format("tab.default_title", sequence)
        currentDirectory = launchConfiguration.localStartDirectory
        executionContext = TerminalExecutionContext.inferred(
            launchConfiguration: launchConfiguration,
            currentDirectory: launchConfiguration.localStartDirectory,
            shellName: nil
        )
    }

    var environment: TerminalEnvironmentKind {
        launchConfiguration.environment
    }

    var safetyPolicy: SSHSafetyConfirmationPolicy {
        launchConfiguration.safetyPolicy
    }

    func prepareController() {
        _ = controller
    }

    /// 后台预热：让 shell 进程在离屏窗口里先跑起来，跑完 rc。仅本地 shell 适用。
    func prewarm(preferences: TerminalPreferences?) {
        guard case .localShell = launchConfiguration else { return }
        controller.prewarm(preferences: preferences)
    }

    /// 从预热态取用：把容器交还给真窗口领养。
    func adoptFromPrewarm() {
        controller.adoptFromPrewarm()
    }

    func startProcessIfNeeded() {
        controller.ensureProcessStarted()
    }

    var canManuallyReconnectSSH: Bool {
        guard case .ssh = launchConfiguration,
              runtimeConnectionIssue != .sessionEnded,
              case .exited = state else {
            return false
        }
        return !hasRunningProcess
    }

    func reconnectSSH() {
        guard canManuallyReconnectSSH else { return }
        controller.reconnectSSH()
    }

    func updateUnreadAttention(_ unread: Bool) {
        guard hasUnreadAttention != unread else { return }
        hasUnreadAttention = unread
    }

    func beginProcessRun() { processRunID = UUID() }

    func clearUnreadAttention() {
        attentionStore?.markViewed(tabID: id)
    }

    func reportBellAttention() {
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .bell)
    }

    func reportProcessExitAttention(exitCode: Int32?) {
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .processExited(exitCode))
    }

    func terminate() {
        guard !sessionWasClosed else { return }
        sessionWasClosed = true
        nativeAgentContext.invalidate()
        updateAgent { $0.exit(now: Date(), close: true) }
        releaseAIControl(reason: "tab_closed")
        cancelRecording()
        controller.terminate()
        onSessionClosed?(id)
    }

    func detachForApplicationExit() {
        cancelRecording()
        do { try aiArchive?.flush(); try aiArchive?.event("viewer_detached") }
        catch { NSLog("MuseTerm could not flush detached input archive") }
        guard didCreateController else { return }
        controller.terminate(preservingRuntime: true)
    }

    var hasRunningProcess: Bool {
        didCreateController && controller.isProcessRunning
    }

    var isRecording: Bool {
        recorder != nil
    }

    func startRecording() {
        guard recorder == nil else { return }
        let now = Date()
        recorder = TerminalShortcutRecorder(startedAt: now)
        activeRecordingStartedAt = now
    }

    func stopRecording(defaultTitle: String? = nil) -> TerminalShortcut? {
        let finishedAt = Date()
        defer {
            recorder = nil
            activeRecordingStartedAt = nil
        }
        let title = defaultTitle ?? L10n.format(
            "shortcut.generated_title",
            Self.shortcutTitleFormatter.string(from: finishedAt)
        )
        return recorder?.finish(
            title: title,
            executionContext: executionContext,
            finishedAt: finishedAt
        )
    }

    func cancelRecording() {
        recorder = nil
        activeRecordingStartedAt = nil
    }

    func recordInputIfNeeded(data: [UInt8], echoEnabled: Bool) {
        guard !isPlayingShortcut else { return }
        recorder?.record(data: data, echoEnabled: echoEnabled)
    }

    // historySnapshot 用 @autoclosure 惰性求值：全量历史快照开销大（全 buffer 扫描），
    // 普通按键不需要它，只有回车提交命令或 Ctrl-C 中断时才真正取一次。
    func observeProcessInput(
        data: [UInt8],
        echoEnabled: Bool,
        historySnapshot: @autoclosure () -> String
    ) {
        guard echoEnabled, !data.isEmpty else { return }

        var cachedSnapshot: String?
        func snapshot() -> String {
            if let cachedSnapshot { return cachedSnapshot }
            let fresh = historySnapshot()
            cachedSnapshot = fresh
            return fresh
        }

        for byte in data {
            switch byte {
            case 0x0D, 0x0A:
                submitPendingCommand(historySnapshot: snapshot())
            case 0x7F, 0x08:
                if !pendingCommandBytes.isEmpty {
                    pendingCommandBytes.removeLast()
                }
            case 0x03:
                finishActiveCommand(
                    exitCode: 130,
                    completionSource: .userInterrupt,
                    historySnapshot: snapshot()
                )
                pendingCommandBytes.removeAll(keepingCapacity: true)
            default:
                if byte == 0x09 || byte >= 0x20 {
                    pendingCommandBytes.append(byte)
                    if pendingCommandBytes.count > 8_192 {
                        pendingCommandBytes.removeFirst(pendingCommandBytes.count - 8_192)
                    }
                }
            }
        }
    }

    func startShellIntegratedCommand(command: String, historySnapshot: String, commandID: UUID? = nil) {
        startCommand(
            command: command,
            startSource: .shellIntegration,
            historySnapshot: historySnapshot,
            commandID: commandID
        )
    }

    func observeProcessOutput(historySnapshot: String) {
        updateHistorySearchSnapshot(historySnapshot)
        guard let activeCommandBlockID,
              let index = commandBlocks.firstIndex(where: { $0.id == activeCommandBlockID }) else {
            return
        }

        let output = historySuffix(from: activeCommandOutputStartIndex, in: historySnapshot)
        commandBlocks[index].outputCharacterCount = output.count
        commandBlocks[index].outputTail = String(output.suffix(maxCommandOutputTailCharacters))
        // 摘要只扫输出尾部窗口：诊断信号几乎都在结尾，避免长输出命令每个输出块都全量重扫。
        let summarySource = output.count > maxOutputSummaryScanCharacters
            ? String(output.suffix(maxOutputSummaryScanCharacters))
            : output
        commandBlocks[index].outputSummary = TerminalOutputInsightAnalyzer.outputSummary(in: summarySource)
    }

    func updateShellName(_ rawShellName: String?) {
        shellName = Self.normalizedShellName(rawShellName)
        refreshExecutionContext()
    }

    func markStartupCommandsStarted() {
        didFinishStartupCommands = false
    }

    func markStartupCommandsFinished() {
        didFinishStartupCommands = true
        attemptPendingContextAction()
    }

    func updateExecutionContext(_ report: TerminalShellReportedContext) {
        guard !report.isEmpty else { return }
        latestReportedContext = report
        if let directory = report.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            currentDirectory = directory
        }
        if let reportedShell = report.shell {
            shellName = Self.normalizedShellName(reportedShell)
        }
        executionContext = TerminalExecutionContext.observed(
            launchConfiguration: launchConfiguration,
            currentDirectory: currentDirectory,
            shellName: shellName,
            report: report
        )
        attemptPendingContextAction()
    }

    func execute(command: String, in expectedContext: TerminalExecutionContext) {
        pendingContextAction = .command(command: command, context: expectedContext, didRequestDirectory: false)
        startProcessIfNeeded()
        attemptPendingContextAction()
    }

    func execute(shortcut: TerminalShortcut, in expectedContext: TerminalExecutionContext) {
        pendingContextAction = .shortcut(shortcut: shortcut, context: expectedContext, didRequestDirectory: false)
        startProcessIfNeeded()
        attemptPendingContextAction()
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard aiLease == nil else { return }
        guard case .running = state else { return }
        guard shortcut.isPlayable, !isRecording, !isPlayingShortcut else { return }
        isPlayingShortcut = true
        Task { [weak self] in
            var protectedBytesCache: [String: [UInt8]] = [:]
            for event in shortcut.events {
                if event.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(event.delayMilliseconds) * 1_000_000)
                }

                let shouldContinue = await MainActor.run {
                    guard let self else { return false }
                    if event.requiresEchoOff, self.controller.terminalEchoEnabled {
                        self.isPlayingShortcut = false
                        return false
                    }
                    return true
                }
                if !shouldContinue { break }

                let bytes = TerminalShortcutEvent.terminalPlaybackBytes(
                    from: event.resolvedBytes(cache: &protectedBytesCache)
                )
                guard !bytes.isEmpty else { continue }
                await MainActor.run {
                    self?.controller.sendProcessInput(bytes: bytes)
                }
            }
            await MainActor.run {
                self?.isPlayingShortcut = false
            }
        }
    }

    func startZModemUpload(fileURLs: [URL]) {
        guard case .running = state else { return }
        startProcessIfNeeded()
        controller.startZModemUpload(fileURLs: fileURLs)
    }

    func startZModemDownload(remotePath: String, destinationFile: URL) {
        guard case .running = state else { return }
        startProcessIfNeeded()
        controller.startZModemDownload(remotePath: remotePath, destinationFile: destinationFile)
    }

    func cancelFileTransfer() {
        controller.requestUserCancelZModemTransfer()
    }

    var canStartSessionTunnel: Bool {
        guard case .running = state,
              sessionTunnelStatus?.occupiesTerminal != true,
              fileTransferStatus?.isActive != true else {
            return false
        }
        return true
    }

    func startSessionTunnel(configuration: SessionTunnelConfiguration) throws {
        guard aiLease == nil else { throw TerminalAIControlError.busy }
        guard canStartSessionTunnel else {
            if sessionTunnelStatus?.occupiesTerminal == true {
                throw SessionTunnelStartError.tunnelAlreadyActive
            }
            if fileTransferStatus?.isActive == true {
                throw SessionTunnelStartError.fileTransferActive
            }
            throw SessionTunnelStartError.processUnavailable
        }
        startProcessIfNeeded()
        try controller.startSessionTunnel(configuration: configuration.validated())
    }

    func stopSessionTunnel() {
        controller.stopSessionTunnel()
    }

    func updateSessionTunnelStatus(_ status: SessionTunnelStatus?) {
        sessionTunnelStatus = status
    }

    func updateFileTransferStatus(_ status: TerminalFileTransferStatus?) {
        fileTransferStatus = status
    }

    func finishActiveCommand(
        exitCode: Int32?,
        completionSource: TerminalCommandCompletionSource = .unknown,
        historySnapshot: String
    ) {
        observeProcessOutput(historySnapshot: historySnapshot)
        guard let activeCommandBlockID,
              let index = commandBlocks.firstIndex(where: { $0.id == activeCommandBlockID }) else {
            return
        }
        commandBlocks[index].endedAt = Date()
        commandBlocks[index].exitCode = exitCode
        commandBlocks[index].completionSource = completionSource
        let finishedBlock = commandBlocks[index]
        updateAgent { $0.endObservedRun(finishedBlock.id, now: Date()) }
        eventStore?.publish(tabID: id, kind: .commandFinished, commandID: finishedBlock.id,
                            commandState: finishedBlock.commandLifecycleState)
        self.activeCommandBlockID = nil
        activeCommandOutputStartIndex = historySnapshot.count
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .commandFinished(finishedBlock))
        commandCompletionHandler?(self, finishedBlock)
    }

    var displayTitle: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("tab.default_title", sequence)
        }
        return title
    }

    var tabTitle: String {
        if let connectionLabel = launchConfiguration.connectionLabel {
            return connectionLabel
        }

        if let remoteIdentity {
            return remoteIdentity
        }

        let directory = directoryLabel
        if directory != "~" {
            return directory
        }

        return L10n.format("tab.default_title", sequence)
    }

    var tabSubtitle: String? {
        if let connectionSubtitle = launchConfiguration.connectionSubtitle {
            return connectionSubtitle
        }

        if remoteIdentity != nil {
            return directoryLabel
        }

        let fallback = L10n.format("tab.default_title", sequence)
        if tabTitle != fallback {
            return nil
        }

        return directoryLabel
    }

    var directoryLabel: String {
        guard let currentDirectory, !currentDirectory.isEmpty else {
            return "~"
        }

        if let url = URL(string: currentDirectory), url.isFileURL {
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }

        let url = URL(fileURLWithPath: currentDirectory)
        return url.lastPathComponent.isEmpty ? currentDirectory : url.lastPathComponent
    }

    var toolStateText: String {
        switch state {
        case .running:
            return "running"
        case .exited(let code):
            if let code {
                return "exited(\(code))"
            }
            return "exited"
        }
    }

    private var remoteIdentity: String? {
        guard let identity = Self.identity(in: title) else { return nil }
        return Self.isLocalIdentity(identity) ? nil : identity
    }

    private static func normalizedShellName(_ rawShellName: String?) -> String? {
        guard var shellName = rawShellName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shellName.isEmpty else {
            return nil
        }

        shellName = shellName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if shellName.contains("/") {
            shellName = URL(fileURLWithPath: shellName).lastPathComponent
        }
        while shellName.hasPrefix("-") {
            shellName.removeFirst()
        }
        guard !shellName.isEmpty else { return nil }
        return shellName.lowercased()
    }

    private static func identity(in title: String) -> String? {
        guard let regex = identityRegex else { return nil }

        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, range: range), match.numberOfRanges >= 3 else {
            return nil
        }

        guard
            let userRange = Range(match.range(at: 1), in: title),
            let hostRange = Range(match.range(at: 2), in: title)
        else {
            return nil
        }

        return "\(title[userRange])@\(title[hostRange])"
    }

    private static func isLocalIdentity(_ identity: String) -> Bool {
        let parts = identity.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }

        let user = parts[0]
        let host = normalizedHost(parts[1])
        guard user == NSUserName() else { return false }

        return localHostNames.contains { localHost in
            host == localHost || host.hasPrefix(localHost) || localHost.hasPrefix(host)
        }
    }

    nonisolated private static let identityRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s:/])([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)"#
    )

    nonisolated private static let localHostNames: Set<String> = {
        var names = [ProcessInfo.processInfo.hostName]
        var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if gethostname(&hostnameBuffer, hostnameBuffer.count) == 0 {
            names.append(String(cString: hostnameBuffer))
        }

        return Set(
            names
                .map(normalizedHost)
                .filter { !$0.isEmpty }
        )
    }()

    nonisolated private static func normalizedHost(_ host: String) -> String {
        host
            .lowercased()
            .replacingOccurrences(of: ".local", with: "")
            .split(separator: ".")
            .first
            .map(String.init) ?? host.lowercased()
    }

    private static let shortcutTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func submitPendingCommand(historySnapshot: String) {
        guard let command = String(bytes: pendingCommandBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty else {
            pendingCommandBytes.removeAll(keepingCapacity: true)
            return
        }

        startCommand(
            command: command,
            startSource: .userInput,
            historySnapshot: historySnapshot
        )
        pendingCommandBytes.removeAll(keepingCapacity: true)
    }

    private func startCommand(
        command: String,
        startSource: TerminalCommandStartSource,
        historySnapshot: String,
        commandID: UUID? = nil
    ) {
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCommand.isEmpty else { return }

        if activeCommandBlockID != nil {
            if startSource == .shellIntegration,
               let index = activeCommandBlockIndex,
               commandBlocks[index].endedAt == nil,
               normalizedCommand(commandBlocks[index].command) == normalizedCommand(cleanCommand) {
                commandBlocks[index].command = String(cleanCommand.prefix(4_000))
                commandBlocks[index].commandStartSource = .shellIntegration
                if let commandID, commandBlocks[index].id != commandID {
                    commandBlocks[index].id = commandID
                    activeCommandBlockID = commandID
                    eventStore?.publish(tabID: id, kind: .commandStarted, commandID: commandID, commandState: .running)
                }
                activeCommandOutputStartIndex = historySnapshot.count
                pendingCommandBytes.removeAll(keepingCapacity: true)
                observeAgentLaunch(command: cleanCommand, runID: commandBlocks[index].id)
                return
            }

            finishActiveCommand(
                exitCode: nil,
                completionSource: .superseded,
                historySnapshot: historySnapshot
            )
        }

        let block = TerminalCommandBlock(
            id: commandID ?? UUID(),
            command: String(cleanCommand.prefix(4_000)),
            workingDirectory: currentDirectory,
            startedAt: Date(),
            endedAt: nil,
            exitCode: nil,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: startSource,
            completionSource: nil,
            executionContext: executionContext
        )
        commandBlocks.append(block)
        if commandBlocks.count > maxCommandBlocks {
            commandBlocks.removeFirst(commandBlocks.count - maxCommandBlocks)
        }
        activeCommandBlockID = block.id
        activeCommandOutputStartIndex = historySnapshot.count
        eventStore?.publish(tabID: id, kind: .commandStarted, commandID: block.id, commandState: .running)
        if startSource == .shellIntegration { observeAgentLaunch(command: cleanCommand, runID: block.id) }

        if Self.entersUnobservedExecutionContext(cleanCommand) {
            latestReportedContext = nil
            refreshExecutionContext()
        }
    }

    private var activeCommandBlockIndex: Int? {
        guard let activeCommandBlockID else { return nil }
        return commandBlocks.firstIndex { $0.id == activeCommandBlockID }
    }

    private func normalizedCommand(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func entersUnobservedExecutionContext(_ command: String) -> Bool {
        let tokens = command
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
        guard let first = tokens.first else { return false }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        if ["ssh", "mosh", "su"].contains(executable) { return true }
        guard executable == "sudo" else { return false }
        return tokens.dropFirst().contains { ["-i", "--login", "-s", "--shell"].contains($0) }
    }

    private func historySuffix(from startIndex: Int, in historySnapshot: String) -> String {
        guard startIndex > 0, startIndex < historySnapshot.count else {
            return startIndex <= 0 ? historySnapshot : ""
        }
        let index = historySnapshot.index(historySnapshot.startIndex, offsetBy: startIndex)
        return String(historySnapshot[index...])
    }

    private func updateHistorySearchSnapshot(_ historySnapshot: String) {
        let nextSnapshot: String
        if historySnapshot.count > maxHistorySearchCharacters {
            nextSnapshot = String(historySnapshot.suffix(maxHistorySearchCharacters))
        } else {
            nextSnapshot = historySnapshot
        }
        guard historySearchSnapshot != nextSnapshot else { return }
        historySearchSnapshot = nextSnapshot
    }

    private enum PendingContextAction {
        case command(command: String, context: TerminalExecutionContext, didRequestDirectory: Bool)
        case shortcut(shortcut: TerminalShortcut, context: TerminalExecutionContext, didRequestDirectory: Bool)

        var context: TerminalExecutionContext {
            switch self {
            case .command(_, let context, _), .shortcut(_, let context, _): return context
            }
        }

        var didRequestDirectory: Bool {
            switch self {
            case .command(_, _, let value), .shortcut(_, _, let value): return value
            }
        }

        func requestingDirectory() -> PendingContextAction {
            switch self {
            case .command(let command, let context, _): return .command(command: command, context: context, didRequestDirectory: true)
            case .shortcut(let shortcut, let context, _): return .shortcut(shortcut: shortcut, context: context, didRequestDirectory: true)
            }
        }
    }

    private func refreshExecutionContext() {
        if let latestReportedContext {
            executionContext = TerminalExecutionContext.observed(
                launchConfiguration: launchConfiguration,
                currentDirectory: currentDirectory,
                shellName: shellName,
                report: latestReportedContext
            )
        } else {
            executionContext = TerminalExecutionContext.inferred(
                launchConfiguration: launchConfiguration,
                currentDirectory: currentDirectory,
                shellName: shellName
            )
        }
    }

    private func attemptPendingContextAction() {
        guard didFinishStartupCommands,
              let report = latestReportedContext,
              let action = pendingContextAction,
              action.context.matchesTarget(of: launchConfiguration) else { return }

        let expected = action.context
        let reportedUser = report.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedUser = expected.normalizedUser,
           let reportedUser,
           expectedUser != reportedUser {
            guard case .command(let command, _, _) = action else {
                pendingContextAction = nil
                NSSound.beep()
                return
            }
            pendingContextAction = nil
            controller.sendProcessInput(bytes: Array(Self.privilegedCommand(command, context: expected).utf8))
            return
        }

        if !expected.matchesReportedContext(report),
           let directory = expected.normalizedDirectory,
           !action.didRequestDirectory {
            pendingContextAction = action.requestingDirectory()
            controller.sendProcessInput(bytes: Array("cd -- \(Self.shellQuoted(directory))\r".utf8))
            return
        }
        guard expected.matchesReportedContext(report) else { return }

        pendingContextAction = nil
        switch action {
        case .command(let command, _, _):
            controller.sendProcessInput(bytes: Array((command + "\r").utf8))
        case .shortcut(let shortcut, _, _):
            playShortcut(shortcut)
        }
    }

    static func privilegedCommand(_ command: String, context: TerminalExecutionContext) -> String {
        let directoryCommand = context.normalizedDirectory.map { "cd -- \(Self.shellQuoted($0)) && " } ?? ""
        let payload = directoryCommand + command
        return "sudo -iu \(Self.shellQuoted(context.normalizedUser ?? "root")) sh -lc \(Self.shellQuoted(payload))\r"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

protocol TerminalTabCloseConfirming {
    func shouldClose(tab: TerminalSession) -> Bool
}

struct SystemTerminalTabCloseConfirmer: TerminalTabCloseConfirming {
    // 「关闭仍在运行的标签」时的「不再询问」开关。分离面板关闭共用同一把钥匙，保证两处一致。
    static let skipRunningTabCloseConfirmationKey = "terminal.skipRunningTabCloseConfirmation"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldClose(tab: TerminalSession) -> Bool {
        guard tab.hasRunningProcess else { return true }
        guard defaults.bool(forKey: Self.skipRunningTabCloseConfirmationKey) == false else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = L10n.string("tab.close_running.title")
        alert.informativeText = L10n.format("tab.close_running.message", tab.tabTitle)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("tab.close_running.action"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("tab.close_running.do_not_ask_again")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: Self.skipRunningTabCloseConfirmationKey)
        }
        return true
    }
}

enum TerminalContextExecutionError: LocalizedError {
    case directoryUnavailable(String)
    case localProfileUnavailable(String)
    case sshProfileUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let directory):
            return L10n.format("learned_command.error.directory_unavailable", directory)
        case .localProfileUnavailable(let profile):
            return L10n.format("learned_command.error.local_profile_unavailable", profile)
        case .sshProfileUnavailable(let profile):
            return L10n.format("learned_command.error.ssh_profile_unavailable", profile)
        }
    }
}

final class TerminalWorkspace: ObservableObject {
    let runtimeWorkspaceID: UUID
    var onRuntimePersistenceNeeded: (() -> Void)?
    var onRuntimeCreationPersistence: (() throws -> Void)?
    var onRuntimeOutputRendered: (() -> Void)?
    var onRuntimeRecordRemovalNeeded: (() -> Void)?
    var pendingRestoredDetachedIDs: [UUID] = []
    @Published var runtimeRecoveryIssue = false
    @Published var runtimeDiscoveryInProgress = false
    let sessionRegistry = TerminalSessionRegistry()
    private(set) var projectLayoutRevision: UInt64 = 0
    @Published var projectLayout = TerminalProjectLayout() {
        didSet {
            if oldValue != projectLayout { projectLayoutRevision += 1; onRuntimePersistenceNeeded?() }
        }
    }
    private var projectEventObservation: UUID?
    var suppressAttentionAutoRead = false
    @Published private(set) var tabs: [TerminalSession] = [] {
        didSet { reconcileProjectLayout() }
    }
    @Published var selectedID: TerminalSession.ID? {
        didSet {
            guard oldValue != selectedID else { return }
            if let selectedID { selectProjectTerminal(selectedID) }
            // 切换选中标签 → 新标签的继承目录变化，按新目录重排预热会话。
            refreshPrewarmIfStale()
            if let selectedID, !suppressAttentionAutoRead { sessionRegistry.attention.markViewed(tabID: selectedID) }
        }
    }
    @Published private(set) var shortcuts: [TerminalShortcut] = TerminalShortcutStore.load()
    @Published private(set) var quickPathRecords: [TerminalQuickPathRecord] = TerminalQuickPathStore.load()
    @Published private(set) var learnedCommands: [LearnedCommandRecord] = []
    @Published private(set) var sessionTunnelPresets: [SessionTunnelPreset] = SessionTunnelPresetStore.load()
    // 被「拉黑」的路径 / 命令：进不了最近·常用列表，也不再被自动记录/学习。
    @Published private(set) var blacklistedQuickPaths: Set<String> = TerminalQuickPathBlacklistStore.load()
    @Published private(set) var blacklistedCommands: Set<String> = LearnedCommandBlacklistStore.load()
    weak var attentionReporter: TerminalAttentionReporting? {
        didSet {
            tabs.forEach { $0.attentionReporter = attentionReporter }
            preparedTab?.attentionReporter = attentionReporter
        }
    }
    // 最后一个标签被关闭后触发；宿主窗口据此关闭自身，未绑定时工作区保持空标签状态。
    var onAllTabsClosed: (() -> Void)?
    // 本地终端 Profile 存储；由 ContentView 注入。未注入时「+」等入口回落系统默认行为。
    weak var profileStore: TerminalProfileStore? {
        didSet {
            // Profile 列表变化（尤其是默认 Profile 被切换）后，预热会话可能烘焙的是旧默认
            // 的 shell：订阅变更（跳过订阅时的首帧当前值），按新默认重排预热。
            profileStoreCancellable = profileStore?.$profiles
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshPrewarmIfStale()
                }
        }
    }
    // 终端偏好；由 ContentView 注入。预热离屏 shell 时用它确定字体/列数等几何，未注入则用默认。
    weak var preferences: TerminalPreferences?

    private let automaticallyStartProcesses: Bool
    private let tabCloseConfirmer: TerminalTabCloseConfirming
    private var nextSequence = 1
    private var preparedTab: TerminalSession?
    // 预热会话已在此目录 spawn 了 shell（rc 已在该目录下跑过）。开标签时只有继承目录与之
    // 完全一致才复用，保证工作目录/rc 副作用（direnv 等）正确，绝不靠事后 cd 兜底。
    private var preparedTabWarmDirectory: String?
    // 预热会话按此 Profile spawn（nil = 系统默认 shell）。开标签时只有请求的 effective
    // profile 与之同一（id 相等）才复用，保证 fish/zsh 等 shell 与 rc 副作用一致。
    private var preparedTabWarmProfile: TerminalProfile?
    private var prewarmRearmWorkItem: DispatchWorkItem?
    private var profileStoreCancellable: AnyCancellable?
    private var isPreparingNextTab = false
    private var lastShortcutNewTabUptime: TimeInterval = -.infinity
    private var lastShortcutNewTabEventTimestamp: TimeInterval?
    private var lastShortcutCloseTabUptime: TimeInterval = -.infinity
    private var lastShortcutCloseTabEventTimestamp: TimeInterval?
    private var quickPathCancellables: [TerminalSession.ID: AnyCancellable] = [:]
    private var lastRecordedQuickPathByTab: [TerminalSession.ID: String] = [:]
    private var pendingQuickPathSaveWorkItem: DispatchWorkItem?
    private var pendingLearnedCommandSaveWorkItem: DispatchWorkItem?
    private var learnedCommandIndex: LearnedCommandIndex
    private var blacklistNotificationCancellable: AnyCancellable?
    private var isClosingTab = false

    init(
        automaticallyStartProcesses: Bool = true,
        tabCloseConfirmer: TerminalTabCloseConfirming = SystemTerminalTabCloseConfirmer(),
        profileStore: TerminalProfileStore? = .shared,
        restoringRuntimeRecord: TerminalRuntimeWorkspaceRecord? = nil,
        deferInitialTab: Bool = false
    ) {
        let recovery = restoringRuntimeRecord.flatMap { record -> TerminalRuntimeWorkspaceRecord? in
            do { try record.validate(); return record } catch { return nil }
        }
        runtimeWorkspaceID = recovery?.workspaceID ?? UUID()
        let loadedLearnedCommands = LearnedCommandStore.load()
        learnedCommandIndex = LearnedCommandIndex(records: loadedLearnedCommands)
        learnedCommands = learnedCommandIndex.records
        self.automaticallyStartProcesses = automaticallyStartProcesses
        self.tabCloseConfirmer = tabCloseConfirmer
        // 设置页撤销拉黑后广播，运行中的工作区据此重载黑名单并刷新最近/常用列表。
        blacklistNotificationCancellable = NotificationCenter.default
            .publisher(for: .recommendationBlacklistChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.blacklistedQuickPaths = TerminalQuickPathBlacklistStore.load()
                self?.blacklistedCommands = LearnedCommandBlacklistStore.load()
            }
        // 必须在首个 newTab() 之前注入 store：否则启动首个标签读不到默认 Profile，
        // 只能回落系统登录 shell（zsh），而 ContentView 的 onAppear 注入来得太晚。
        // 默认取共享单例（与 ContentView 注入的是同一实例）；测试可显式传 nil。
        self.profileStore = profileStore
        projectEventObservation = sessionRegistry.events.observe { [weak self] event in
            if [.closed, .locationChanged].contains(event.kind) { self?.reconcileProjectLayout() }
            if event.kind == .closed, self?.sessionRegistry.sessions.isEmpty == true { self?.onRuntimeRecordRemovalNeeded?() }
            if [.agentChanged, .attentionCreated, .attentionUpdated, .attentionResolved].contains(event.kind) {
                self?.objectWillChange.send()
            }
        }
        if let recovery { installRuntimeRecord(recovery) }
        else {
            runtimeRecoveryIssue = restoringRuntimeRecord != nil
            if !deferInitialTab { newTab() }
        }
    }

    deinit {
        if let projectEventObservation { sessionRegistry.events.removeObserver(projectEventObservation) }
        flushPendingQuickPathSave()
        flushPendingLearnedCommandSave()
        preparedTab?.terminate()
    }

    var selectedTab: TerminalSession? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID } ?? tabs.first
    }

    @discardableResult
    func newTab(startDirectory: String? = nil, profile: TerminalProfile? = nil) -> TerminalSession {
        // profile 显式传入时用它，否则回落默认 profile（未注入 store 时为 nil = 系统默认）。
        let effectiveProfile = (profile ?? profileStore?.defaultProfile)?.normalized
        let resolvedStartDirectory = resolvedNewLocalTabStartDirectory(
            explicitStartDirectory: startDirectory,
            profile: effectiveProfile
        )
        // 预热快路径：继承目录与请求 Profile 都与预热会话一致才复用已就绪的 warm shell
        // （近似秒开）；任一对不上则老实冷建，绝不靠事后 cd / 换 shell 兜底。
        let tab: TerminalSession
        if let warmTab = takePreparedTabIfMatches(
            directory: canonicalNewTabDirectory(resolvedStartDirectory),
            profile: effectiveProfile
        ) {
            tab = warmTab
        } else {
            let profileForConfig = (effectiveProfile?.isSystemEquivalent ?? true) ? nil : effectiveProfile
            tab = makeTab(
                launchConfiguration: .localShell(startDirectory: resolvedStartDirectory, profile: profileForConfig)
            )
        }
        tab.attentionReporter = attentionReporter
        tabs.append(tab)
        sessionRegistry.register(tab)
        trackQuickPaths(for: tab)
        selectedID = tab.id
        tab.clearUnreadAttention()
        if automaticallyStartProcesses {
            DispatchQueue.main.async {
                tab.startProcessIfNeeded()
            }
        }
        schedulePrepareNextTab()
        return tab
    }

    private func resolvedNewLocalTabStartDirectory(
        explicitStartDirectory: String?,
        profile: TerminalProfile?
    ) -> String? {
        if explicitStartDirectory != nil {
            return TerminalWorkingDirectory.normalizedExistingDirectory(explicitStartDirectory)
        }

        // profile 指定了默认工作目录时优先使用，其次继承当前本地标签目录。
        if let directory = profile?.workingDirectory, !directory.isEmpty,
           let normalized = TerminalWorkingDirectory.normalizedExistingDirectory(directory) {
            return normalized
        }

        guard let selectedTab,
              case .localShell(let launchStartDirectory, _) = selectedTab.launchConfiguration else {
            return nil
        }

        return TerminalWorkingDirectory.normalizedExistingDirectory(selectedTab.currentDirectory)
            ?? TerminalWorkingDirectory.normalizedExistingDirectory(launchStartDirectory)
    }

    @discardableResult
    func openSSH(profile: SSHConnectionProfile) -> TerminalSession {
        let tab = makeTab(launchConfiguration: .ssh(profile))
        tab.attentionReporter = attentionReporter
        tabs.append(tab)
        sessionRegistry.register(tab)
        trackQuickPaths(for: tab)
        selectedID = tab.id
        tab.clearUnreadAttention()
        if automaticallyStartProcesses {
            DispatchQueue.main.async {
                tab.startProcessIfNeeded()
            }
        }
        return tab
    }

    func saveSnapshot() throws {
        guard !sessionRegistry.sessions.values.contains(where: \.runtimeAttachOnly) else {
            throw TerminalWorkspaceSnapshotError.unsupportedTab
        }
        let snapshotTabs = sessionRegistry.sessions.values.sorted { $0.sequence < $1.sequence }.map { tab -> TerminalWorkspaceSnapshot.Tab in
            var saved: TerminalWorkspaceSnapshot.Tab
            switch tab.launchConfiguration {
            case .localShell(let startDirectory, let profile):
                saved = .local(directory: tab.currentDirectory ?? startDirectory, profile: profile)
            case .ssh(let profile):
                saved = .ssh(profile: profile)
            }
            saved.terminalID = tab.id
            return saved
        }

        guard !snapshotTabs.isEmpty else {
            throw TerminalWorkspaceSnapshotError.emptyWorkspace
        }

        let selectedIndex = selectedTab.flatMap { selected in
            tabs.firstIndex { $0.id == selected.id }
        } ?? 0

        let snapshot = TerminalWorkspaceSnapshot(
            selectedIndex: min(max(selectedIndex, 0), snapshotTabs.count - 1),
            tabs: snapshotTabs, projectLayout: projectLayout
        )
        try TerminalWorkspaceSnapshotStore.save(snapshot)
    }

    func runtimeWorkspaceRecord() throws -> TerminalRuntimeWorkspaceRecord {
        let sessions = sessionRegistry.sessions.values.sorted { $0.sequence < $1.sequence }
        let saved = sessions.map { session -> TerminalWorkspaceSnapshot.Tab in
            var tab: TerminalWorkspaceSnapshot.Tab
            switch session.launchConfiguration {
            case .localShell(let directory, let profile):
                var reference = profile
                reference?.environment = [:]
                reference?.startupCommands = []
                reference?.customPrompt = ""
                tab = .local(directory: session.currentDirectory ?? directory, profile: reference)
            case .ssh(var profile):
                profile.extraOptions = []
                profile.startupCommands = []
                tab = .ssh(profile: profile)
            }
            tab.terminalID = session.id
            tab.runtimeGeneration = session.runtimeInfo?.generation ?? session.runtimeGenerationToRestore
            tab.runtimeRequiresExisting = session.runtimeRequiresExisting || tab.runtimeGeneration != nil
            tab.runtimePendingCreationEpoch = session.runtimePendingCreationEpoch
            tab.runtimeRenderedCursor = session.runtimeRenderedCursor
            tab.runtimeAttachOnly = session.runtimeAttachOnly ? true : nil
            return tab
        }
        let selected = selectedID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? 0
        let snapshot = TerminalWorkspaceSnapshot(selectedIndex: selected, tabs: saved, projectLayout: projectLayout)
        let record = TerminalRuntimeWorkspaceRecord(workspaceID: runtimeWorkspaceID, snapshot: snapshot,
            detachedIDs: Set(sessionRegistry.locations.filter { $0.value == .detached }.map(\.key) + pendingRestoredDetachedIDs)
                .sorted { $0.uuidString < $1.uuidString })
        try record.validate()
        return record
    }

    private func installRuntimeRecord(_ record: TerminalRuntimeWorkspaceRecord) {
        let ids = record.snapshot.tabs.compactMap(\.terminalID)
        guard let layout = try? record.snapshot.restoredProjectLayout(terminalIDs: ids, defaultName: L10n.string("project.default")) else { return }
        let sshProfiles = SSHConnectionStore().profiles
        let restored = zip(record.snapshot.tabs, ids).map { saved, id -> TerminalSession in
            let configuration: TerminalLaunchConfiguration
            var missingProfile = false
            if let profile = saved.sshProfile, saved.kind == .ssh {
                let current = sshProfiles.first { $0.id == profile.id }
                missingProfile = current == nil
                configuration = .ssh((current ?? profile).normalized)
            } else {
                let current = saved.localProfile.flatMap { profileStore?.profile(id: $0.id) }
                missingProfile = saved.localProfile != nil && current == nil
                configuration = .localShell(startDirectory: saved.localDirectory, profile: (current ?? saved.localProfile)?.normalized)
            }
            let session = makeTab(launchConfiguration: configuration, id: id)
            session.runtimeGenerationToRestore = saved.runtimeGeneration
            session.runtimePendingCreationEpoch = saved.runtimePendingCreationEpoch
            session.runtimeRenderedCursorToRestore = saved.runtimeRenderedCursor
            session.runtimeAttachOnly = saved.runtimeAttachOnly == true
            if session.runtimeAttachOnly { session.title = L10n.string("runtime.recovered_terminal") }
            session.runtimeRequiresExisting = saved.runtimeRequiresExisting == true || saved.runtimeGeneration != nil || missingProfile
            session.runtimeRestoresLocalShell = saved.kind == .local && !missingProfile && !session.runtimeAttachOnly
                && configuration.localProfile?.shell != .custom
            return session
        }
        tabs = restored
        projectLayout = layout
        restored.forEach { sessionRegistry.register($0); trackQuickPaths(for: $0) }
        pendingRestoredDetachedIDs = record.detachedIDs
        selectedID = layout.focusedTerminalID ?? restored.first?.id
    }

    /// Lost layout/configuration cannot be reconstructed from a PTY PID. Keep
    /// these terminals attach-only rather than guessing a local/SSH profile.
    func adoptRuntimeOrphans(_ infos: [TerminalRuntimeSessionInfo], root: URL) throws {
        let available = infos.filter { sessionRegistry.sessions[$0.id] == nil }
        guard !available.isEmpty else { return }
        var layout = projectLayout
        let project = try layout.addProject(name: L10n.string("runtime.recovered_project"))
        let recovered = available.map { info -> TerminalSession in
            let session = makeTab(launchConfiguration: .localShell(startDirectory: nil), id: info.id)
            session.runtimeRequiresExisting = true
            session.runtimeGenerationToRestore = info.generation
            session.runtimeRenderedCursorToRestore = .init(generation: info.generation, offset: info.outputOffset)
            session.runtimeAttachOnly = true
            session.runtimeRecoveryRoot = root
            session.title = L10n.string("runtime.recovered_terminal")
            return session
        }
        for session in recovered { try layout.addTab(terminal: session.id, projectID: project) }
        let wasEmpty = tabs.isEmpty
        if !wasEmpty { layout.selectedProjectID = projectLayout.selectedProjectID }
        recovered.forEach { sessionRegistry.register($0) }
        tabs.append(contentsOf: recovered)
        projectLayout = layout
        if wasEmpty { selectedID = recovered.first?.id }
        onRuntimePersistenceNeeded?()
        if automaticallyStartProcesses {
            recovered.forEach { session in DispatchQueue.main.async { session.startProcessIfNeeded() } }
        }
    }

    func detachRuntimeForApplicationExit() {
        prewarmRearmWorkItem?.cancel()
        preparedTab?.terminate()
        preparedTab = nil
        isPreparingNextTab = false
        for session in sessionRegistry.sessions.values { session.detachForApplicationExit() }
    }

    func restoreSnapshot() throws {
        let snapshot = try TerminalWorkspaceSnapshotStore.load()
        guard !snapshot.tabs.isEmpty else {
            throw TerminalWorkspaceSnapshotError.emptyWorkspace
        }

        let restoredTabs = try snapshot.tabs.map { tabSnapshot -> TerminalSession in
            switch tabSnapshot.kind {
            case .local:
                // 恢复时优先按 id 取回最新 profile（用户可能已改），取不到再用快照内嵌副本。
                let snapshotProfile = tabSnapshot.localProfile?.normalized
                let resolvedProfile = snapshotProfile.flatMap { profileStore?.profile(id: $0.id)?.normalized } ?? snapshotProfile
                return makeTab(
                    launchConfiguration: .localShell(
                        startDirectory: TerminalWorkingDirectory.normalizedExistingDirectory(tabSnapshot.localDirectory),
                        profile: (resolvedProfile?.isSystemEquivalent ?? true) ? nil : resolvedProfile
                    )
                )
            case .ssh:
                guard let profile = tabSnapshot.sshProfile else {
                    throw TerminalWorkspaceSnapshotError.unsupportedTab
                }
                return makeTab(launchConfiguration: .ssh(profile.normalized))
            }
        }

        let restoredLayout = try snapshot.restoredProjectLayout(terminalIDs: restoredTabs.map(\.id), defaultName: L10n.string("project.default"))

        preparedTab?.terminate()
        preparedTab = nil
        preparedTabWarmDirectory = nil
        preparedTabWarmProfile = nil
        prewarmRearmWorkItem?.cancel()
        isPreparingNextTab = false
        tabs.forEach { $0.terminate() }
        quickPathCancellables.removeAll()
        lastRecordedQuickPathByTab.removeAll()
        tabs = restoredTabs
        projectLayout = restoredLayout
        tabs.forEach { sessionRegistry.register($0) }
        tabs.forEach { $0.attentionReporter = attentionReporter }
        tabs.forEach(trackQuickPaths)

        let selectedIndex = min(max(snapshot.selectedIndex, 0), tabs.count - 1)
        selectedID = restoredLayout.focusedTerminalID ?? tabs[selectedIndex].id
        tabs[selectedIndex].clearUnreadAttention()

        if automaticallyStartProcesses {
            let tabsToStart = tabs
            DispatchQueue.main.async {
                tabsToStart.forEach { $0.startProcessIfNeeded() }
            }
        }

        schedulePrepareNextTab()
    }

    func newTabFromShortcut(eventTimestamp: TimeInterval? = nil) {
        if let eventTimestamp {
            guard eventTimestamp != lastShortcutNewTabEventTimestamp else { return }
            lastShortcutNewTabEventTimestamp = eventTimestamp
            newTab()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShortcutNewTabUptime > 0.2 else { return }
        lastShortcutNewTabUptime = now
        newTab()
    }

    func openQuickPath(_ record: TerminalQuickPathRecord) {
        openQuickPath(record.path)
    }

    @discardableResult
    func addQuickPath(_ path: String) -> TerminalQuickPathRecord? {
        guard let normalizedPath = TerminalWorkingDirectory.normalizedExistingDirectory(path) else {
            return nil
        }
        quickPathRecords = TerminalQuickPathStore.record(directory: normalizedPath, in: quickPathRecords)
        flushPendingQuickPathSave()
        return quickPathRecords.first { $0.path == normalizedPath }
    }

    func openQuickPath(_ path: String) {
        guard let normalizedPath = TerminalWorkingDirectory.normalizedExistingDirectory(path) else {
            removeQuickPath(path)
            return
        }
        newTab(startDirectory: normalizedPath)
    }

    var recentQuickPaths: [TerminalQuickPathRecord] {
        TerminalQuickPathStore.recent(
            quickPathRecords.filter { !blacklistedQuickPaths.contains($0.path) },
            limit: 3
        )
    }

    func frequentQuickPaths(limit: Int, excludingPaths: Set<String> = []) -> [TerminalQuickPathRecord] {
        TerminalQuickPathStore.frequent(
            quickPathRecords,
            limit: limit,
            excludingPaths: excludingPaths.union(blacklistedQuickPaths)
        )
    }

    /// 拉黑路径：加入黑名单并从记录中移除。之后无论访问多频繁都不再出现在最近/常用里。
    func blacklistQuickPath(_ path: String) {
        guard let normalizedPath = TerminalWorkingDirectory.normalizedExistingDirectory(path)
            ?? path.nonEmptyTrimmed else { return }
        blacklistedQuickPaths.insert(normalizedPath)
        TerminalQuickPathBlacklistStore.save(blacklistedQuickPaths)
        quickPathRecords.removeAll { $0.path == normalizedPath }
        scheduleQuickPathSave()
    }

    @discardableResult
    func closeSelectedTabFromShortcut(eventTimestamp: TimeInterval? = nil) -> Bool {
        guard !isClosingTab else { return false }
        guard shouldHandleCloseTabShortcut(eventTimestamp: eventTimestamp) else { return false }
        return closeSelectedTab()
    }

    func select(_ tab: TerminalSession) {
        selectedID = tab.id
        if !suppressAttentionAutoRead { tab.clearUnreadAttention() }
    }

    func selectNextTab() {
        selectRelativeTab(offset: 1)
    }

    func selectPreviousTab() {
        selectRelativeTab(offset: -1)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
        tabs[index].clearUnreadAttention()
    }

    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let selectedTab else { return false }
        return close(selectedTab)
    }

    @discardableResult
    func close(_ tab: TerminalSession, skipConfirmation: Bool = false) -> Bool {
        guard !isClosingTab else { return false }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        isClosingTab = true
        defer { isClosingTab = false }

        guard skipConfirmation || tabCloseConfirmer.shouldClose(tab: tab) else { return false }

        tab.terminate()
        tabs.remove(at: index)
        quickPathCancellables[tab.id] = nil
        lastRecordedQuickPathByTab[tab.id] = nil

        guard !tabs.isEmpty else {
            selectedID = nil
            onAllTabsClosed?()
            return true
        }

        if selectedID == tab.id {
            selectedID = projectLayout.focusedTerminalID ?? tabs[min(index, tabs.count - 1)].id
            if !suppressAttentionAutoRead { selectedTab?.clearUnreadAttention() }
        }

        return true
    }

    /// 分离标签：把 session 从工作区摘出，但**不终止**其进程（top / tail -f 继续跑），
    /// 交给悬浮面板继续托管渲染。若摘出后主窗口会一个标签不剩，则补一个新标签避免空窗关窗。
    /// 返回被摘出的 session；未找到或正处于关闭流程中返回 nil。
    @discardableResult
    func detachTab(_ tab: TerminalSession) -> TerminalSession? {
        guard !isClosingTab else { return nil }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        isClosingTab = true
        defer { isClosingTab = false }

        sessionRegistry.move(tab.id, to: .detached)
        tabs.remove(at: index)
        quickPathCancellables[tab.id] = nil
        lastRecordedQuickPathByTab[tab.id] = nil

        if tabs.isEmpty {
            // 主窗口不能空着（空标签会触发 onAllTabsClosed 关窗），补一个新标签；
            // 被分离的 session 已交给面板，绝不在此终止。
            newTab()
        } else if selectedID == tab.id {
            let fallbackIndex = min(index, tabs.count - 1)
            selectedID = tabs[fallbackIndex].id
            tabs[fallbackIndex].clearUnreadAttention()
        }
        return tab
    }

    /// 收回分离标签：把悬浮面板托管的 session 塞回工作区并选中。已在工作区中则忽略。
    @discardableResult
    func reattachTab(_ tab: TerminalSession) -> Bool {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return false }
        tab.attentionReporter = attentionReporter
        tabs.append(tab)
        sessionRegistry.register(tab)
        trackQuickPaths(for: tab)
        selectedID = tab.id
        tab.clearUnreadAttention()
        return true
    }

    private func shouldHandleCloseTabShortcut(eventTimestamp: TimeInterval?) -> Bool {
        if let eventTimestamp {
            guard eventTimestamp != lastShortcutCloseTabEventTimestamp else { return false }
            lastShortcutCloseTabEventTimestamp = eventTimestamp
            lastShortcutCloseTabUptime = ProcessInfo.processInfo.systemUptime
            return true
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShortcutCloseTabUptime > 0.2 else { return false }
        lastShortcutCloseTabUptime = now
        return true
    }

    var isRecording: Bool {
        tabs.contains { $0.isRecording }
    }

    func startRecordingSelectedTab() {
        guard !isRecording, let selectedTab else { return }
        selectedTab.startProcessIfNeeded()
        selectedTab.startRecording()
        objectWillChange.send()
    }

    func stopRecording() {
        guard let tab = tabs.first(where: { $0.isRecording }) else { return }
        guard let shortcut = tab.stopRecording() else {
            objectWillChange.send()
            return
        }
        upsertShortcut(shortcut)
        objectWillChange.send()
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard !isRecording else { return }
        selectedTab?.playShortcut(shortcut)
        objectWillChange.send()
    }

    func setShortcutRequiresUserAuthentication(_ enabled: Bool, id: UUID) {
        updateShortcut(id: id) { $0.requiresUserAuthentication = enabled }
    }

    func setShortcutAllowsAutomationPlayback(_ enabled: Bool, id: UUID) {
        updateShortcut(id: id) { $0.allowsAutomationPlayback = enabled }
    }

    private func updateShortcut(id: UUID, mutate: (inout TerminalShortcut) -> Void) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var shortcut = shortcuts[index]
        mutate(&shortcut)
        shortcut.updatedAt = Date()
        shortcuts[index] = shortcut.normalized
        persistShortcuts()
    }

    var discoverableLearnedCommands: [LearnedCommandRecord] {
        learnedCommands.filter { $0.isDiscoverable && !blacklistedCommands.contains($0.command) }
    }

    /// 拉黑命令：加入黑名单并移除该记录。之后无论执行多少次都不再作为常用命令建议。
    func blacklistLearnedCommand(id: String) {
        guard let record = learnedCommands.first(where: { $0.id == id }) else { return }
        blacklistedCommands.insert(record.command)
        LearnedCommandBlacklistStore.save(blacklistedCommands)
        removeLearnedCommand(id: id)
    }

    func executeLearnedCommand(
        _ record: LearnedCommandRecord,
        sshProfiles: [SSHConnectionProfile]
    ) throws {
        let tab = try newTab(for: record.context, sshProfiles: sshProfiles)
        learnedCommandIndex.markExecuted(id: record.id)
        publishLearnedCommands()
        tab.execute(command: record.command, in: record.context)
    }

    func playShortcutInRecordedContext(
        _ shortcut: TerminalShortcut,
        sshProfiles: [SSHConnectionProfile]
    ) throws {
        guard let context = shortcut.executionContext else {
            playShortcut(shortcut)
            return
        }
        let tab = try newTab(for: context, sshProfiles: sshProfiles)
        tab.execute(shortcut: shortcut, in: context)
    }

    /// 本人在界面里发起的回放。需要验证时先弹 Touch ID，通过后才播放。
    func playUserShortcut(
        _ shortcut: TerminalShortcut,
        sshProfiles: [SSHConnectionProfile],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        TerminalShortcutPlayback.begin(shortcut: shortcut, origin: .user, invalidateAfter: nil) { [weak self] result in
            guard let self else {
                completion(.failure(TerminalShortcutPlaybackError.authenticationCancelled))
                return
            }
            switch result {
            case .success:
                do {
                    try self.playShortcutInRecordedContext(shortcut, sshProfiles: sshProfiles)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func setLearnedCommandPinned(_ pinned: Bool, id: String) {
        learnedCommandIndex.setPinned(pinned, id: id)
        publishLearnedCommands()
    }

    func dismissLearnedCommand(id: String) {
        learnedCommandIndex.dismiss(id: id)
        publishLearnedCommands()
    }

    func removeLearnedCommand(id: String) {
        learnedCommandIndex.remove(id: id)
        publishLearnedCommands()
    }

    func startZModemUpload(fileURLs: [URL]) {
        selectedTab?.startZModemUpload(fileURLs: fileURLs)
        objectWillChange.send()
    }

    func startZModemDownload(remotePath: String, destinationFile: URL) {
        selectedTab?.startZModemDownload(remotePath: remotePath, destinationFile: destinationFile)
        objectWillChange.send()
    }

    func cancelFileTransfer() {
        selectedTab?.cancelFileTransfer()
        objectWillChange.send()
    }

    func renameShortcut(id: UUID, title: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var shortcut = shortcuts[index]
        shortcut.title = title
        shortcut.updatedAt = Date()
        shortcuts[index] = shortcut.normalized
        persistShortcuts()
    }

    func deleteShortcut(id: UUID) {
        for shortcut in shortcuts where shortcut.id == id {
            TerminalShortcutStore.deleteProtectedInputs(for: shortcut)
        }
        shortcuts.removeAll { $0.id == id }
        persistShortcuts()
    }

    func editableShortcutsText() -> String {
        TerminalShortcutStore.editableText(for: shortcuts)
    }

    func saveEditableShortcutsText(_ text: String) throws {
        let edited = try TerminalShortcutStore.decodeEditableText(text)
        TerminalShortcutStore.deleteProtectedInputs(removedFrom: shortcuts, keeping: edited)
        shortcuts = edited
        TerminalShortcutStore.save(shortcuts)
    }

    private func selectRelativeTab(offset: Int) {
        guard tabs.count > 1 else { return }

        let currentIndex = selectedTab.flatMap { selected in
            tabs.firstIndex { $0.id == selected.id }
        } ?? 0

        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        selectedID = tabs[nextIndex].id
        tabs[nextIndex].clearUnreadAttention()
    }

    func toolSnapshots(maxHistoryCharacters: Int) -> [TerminalToolTabSnapshot] {
        tabs.enumerated().map { offset, tab in
            tab.controller.toolSnapshot(
                index: offset + 1,
                isSelected: selectedTab?.id == tab.id,
                maxHistoryCharacters: maxHistoryCharacters
            )
        }
    }

    func sendToolInput(to selector: String?, bytes: [UInt8], owner: String? = nil) throws -> TerminalSession {
        let tab = try toolTab(matching: selector)
        try tab.authorizeAIInput(owner: owner)
        tab.startProcessIfNeeded()
        if tab.controller.runtimeHandle != nil {
            // The runtime ACK comes back on the main queue, so waiting for it
            // here would deadlock the caller. Hand the bytes to the input queue
            // and let its completion report the result.
            let lease = try tab.runtimeToolInputOwner(requested: owner)
            try tab.controller.enqueueRuntimeToolInput(bytes, owner: lease.owner,
                afterSettled: lease.releaseAfterWrite ? { [weak tab] in
                    if tab?.aiLease?.owner == lease.owner { tab?.releaseAIControl(reason: "assistant_filled") }
                } : nil)
        } else {
            try tab.controller.sendToolInput(bytes: bytes, owner: owner)
            if let owner, tab.aiLease != nil { try tab.renewAIControl(owner: owner) }
        }
        return tab
    }

    func startToolSessionTunnel(
        configuration: SessionTunnelConfiguration,
        in selector: String?
    ) throws -> TerminalSession {
        let tab = try toolTab(matching: selector)
        try tab.authorizeAIInput(owner: nil)
        try tab.startSessionTunnel(configuration: configuration)
        sessionTunnelPresets = SessionTunnelPresetStore.record(configuration)
        objectWillChange.send()
        return tab
    }

    func recordSessionTunnelPreset(_ configuration: SessionTunnelConfiguration) {
        sessionTunnelPresets = SessionTunnelPresetStore.record(configuration)
    }

    func stopToolSessionTunnel(in selector: String?) throws -> TerminalSession {
        let tab = try toolTab(matching: selector)
        guard tab.sessionTunnelStatus != nil else {
            throw TerminalToolError.sessionTunnelNotActive
        }
        tab.stopSessionTunnel()
        objectWillChange.send()
        return tab
    }

    func playToolShortcut(_ shortcut: TerminalShortcut, in selector: String?) throws -> TerminalSession {
        let tab = try toolTab(matching: selector)
        tab.startProcessIfNeeded()
        tab.playShortcut(shortcut)
        objectWillChange.send()
        return tab
    }

    /// MCP / CLI 回放。先过自动化门禁，再按需要等本人按指纹，最后才播放。
    func playAutomationShortcut(
        _ shortcut: TerminalShortcut,
        in selector: String?,
        wait: TimeInterval,
        completion: @escaping (Result<TerminalSession, TerminalShortcutPlaybackError>) -> Void
    ) {
        TerminalShortcutPlayback.begin(
            shortcut: shortcut,
            origin: .automation,
            invalidateAfter: wait
        ) { [weak self] result in
            guard let self else {
                completion(.failure(.authenticationCancelled))
                return
            }
            switch result {
            case .success:
                do {
                    completion(.success(try self.playToolShortcut(shortcut, in: selector)))
                } catch {
                    completion(.failure(.notPlayable))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func toolTab(matching selector: String?) throws -> TerminalSession {
        let cleaned = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty, cleaned != "selected" else {
            if let selectedTab { return selectedTab }
            if let first = tabs.first { return first }
            throw TerminalToolError.tabNotFound("selected")
        }

        // Detached sessions remain addressable by exact UUID; visible indexes keep their meaning.
        if let id = UUID(uuidString: cleaned), let session = sessionRegistry.sessions[id] { return session }

        if let index = Int(cleaned), tabs.indices.contains(index - 1) {
            return tabs[index - 1]
        }

        if let exact = tabs.first(where: { $0.id.uuidString == cleaned }) {
            return exact
        }

        if let prefix = tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(cleaned.lowercased()) }) {
            return prefix
        }

        if let titled = tabs.first(where: { $0.tabTitle == cleaned || $0.displayTitle == cleaned }) {
            return titled
        }

        throw TerminalToolError.tabNotFound(cleaned)
    }

    private var canonicalHomeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    // 一个默认新标签实际会落到的目录：解析后的继承目录，为 nil 时 shell 回落到 home。
    private func canonicalNewTabDirectory(_ resolvedStartDirectory: String?) -> String {
        resolvedStartDirectory ?? canonicalHomeDirectory
    }

    /// 仅当预热会话正是在 `directory` 里、且用同一 `profile` spawn 的才取用；否则返回 nil 让调用方冷建。
    private func takePreparedTabIfMatches(directory: String, profile: TerminalProfile?) -> TerminalSession? {
        guard let preparedTab,
              preparedTabWarmDirectory == directory,
              preparedTabWarmProfile?.id == profile?.id else { return nil }
        self.preparedTab = nil
        preparedTabWarmDirectory = nil
        preparedTabWarmProfile = nil
        preparedTab.attentionReporter = attentionReporter
        preparedTab.adoptFromPrewarm()
        return preparedTab
    }

    private func makeTab(launchConfiguration: TerminalLaunchConfiguration = .localShell(), id: UUID = UUID()) -> TerminalSession {
        let tab = TerminalSession(sequence: nextSequence, launchConfiguration: launchConfiguration, id: id)
        tab.onRuntimeIdentityChanged = { [weak self] in self?.onRuntimePersistenceNeeded?() }
        tab.onRuntimeCreationChanged = { [weak self] in try self?.onRuntimeCreationPersistence?() }
        tab.onRuntimeOutputRendered = { [weak self] in self?.onRuntimeOutputRendered?() }
        tab.onNewLocalTerminal = { [weak self, weak tab] in
            _ = self?.newTab(startDirectory: tab?.launchConfiguration.localStartDirectory)
        }
        tab.attentionReporter = attentionReporter
        tab.commandCompletionHandler = { [weak self] session, block in
            self?.observeCompletedCommand(block, in: session)
        }
        nextSequence += 1
        return tab
    }

    private func newTab(
        for context: TerminalExecutionContext,
        sshProfiles: [SSHConnectionProfile]
    ) throws -> TerminalSession {
        switch context.targetKind {
        case .local:
            if let directory = context.normalizedDirectory,
               TerminalWorkingDirectory.normalizedExistingDirectory(directory) == nil {
                throw TerminalContextExecutionError.directoryUnavailable(directory)
            }
            let profile = context.targetID.flatMap { profileStore?.profile(id: $0) }
            if context.targetID != nil, profile == nil {
                throw TerminalContextExecutionError.localProfileUnavailable(context.displayTarget)
            }
            return newTab(startDirectory: context.normalizedDirectory, profile: profile)
        case .ssh:
            guard let profile = sshProfiles.first(where: {
                context.targetID == $0.id
                    && context.targetFingerprint == TerminalExecutionContext.sshFingerprint($0)
            }) else {
                throw TerminalContextExecutionError.sshProfileUnavailable(context.displayTarget)
            }
            var executionProfile = profile
            executionProfile.remoteShellIntegrationEnabled = true
            return openSSH(profile: executionProfile)
        }
    }

    private func observeCompletedCommand(_ block: TerminalCommandBlock, in session: TerminalSession) {
        let context = block.executionContext ?? session.executionContext
        // 已拉黑的命令不再学习/记录（与 record.command 同源的归一化形式比对）。
        guard !blacklistedCommands.contains(LearnedCommandEligibility.normalizedCommand(block.command)) else { return }
        guard learnedCommandIndex.observe(block: block, context: context) != nil else { return }
        publishLearnedCommands()
    }

    private func publishLearnedCommands() {
        learnedCommands = learnedCommandIndex.records
        pendingLearnedCommandSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingLearnedCommandSave()
        }
        pendingLearnedCommandSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    private func flushPendingLearnedCommandSave() {
        pendingLearnedCommandSaveWorkItem?.cancel()
        pendingLearnedCommandSaveWorkItem = nil
        LearnedCommandStore.saveAsync(learnedCommands)
    }

    private func schedulePrepareNextTab() {
        guard automaticallyStartProcesses, !TerminalRuntimeService.isEnabled else { return }
        guard preparedTab == nil, !isPreparingNextTab else { return }
        isPreparingNextTab = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.prepareNextTab()
        }
    }

    private func prepareNextTab() {
        defer { isPreparingNextTab = false }
        guard preparedTab == nil, !TerminalRuntimeService.isEnabled else { return }

        // 预热跟随默认 Profile：默认是 fish 就预热 fish、是系统默认就预热登录 shell，
        // 让「点 + / 快捷键开默认标签」这条最高频路径无论用哪种 shell 都能秒开。
        let warmProfile = profileStore?.defaultProfile.normalized
        // 把「此刻一个默认新标签会继承到的目录」烘焙进预热会话（含 Profile 自带 workingDirectory），
        // 令 warm shell 直接在该目录起。
        let warmDirectory = canonicalNewTabDirectory(
            resolvedNewLocalTabStartDirectory(explicitStartDirectory: nil, profile: warmProfile)
        )
        let profileForConfig = (warmProfile?.isSystemEquivalent ?? true) ? nil : warmProfile
        let tab = makeTab(launchConfiguration: .localShell(startDirectory: warmDirectory, profile: profileForConfig))
        tab.prewarm(preferences: preferences)
        preparedTab = tab
        preparedTabWarmDirectory = warmDirectory
        preparedTabWarmProfile = warmProfile
    }

    /// 当前选中标签的目录变化后，预热会话烘焙的目录可能已过期：丢弃并按新目录重排一个。
    /// 防抖，避免用户连续 cd 时反复 spawn shell。
    func refreshPrewarmIfStale() {
        guard automaticallyStartProcesses else { return }
        prewarmRearmWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let warmProfile = self.profileStore?.defaultProfile.normalized
            let desired = self.canonicalNewTabDirectory(
                self.resolvedNewLocalTabStartDirectory(explicitStartDirectory: nil, profile: warmProfile)
            )
            // 已有预热且目录、默认 Profile 都仍匹配：无需动作。
            if self.preparedTab != nil,
               self.preparedTabWarmDirectory == desired,
               self.preparedTabWarmProfile?.id == warmProfile?.id { return }
            // 目录或默认 Profile 过期：拆掉旧预热，重新按新目录 / Profile 预热。
            self.preparedTab?.terminate()
            self.preparedTab = nil
            self.preparedTabWarmDirectory = nil
            self.preparedTabWarmProfile = nil
            self.isPreparingNextTab = false
            self.schedulePrepareNextTab()
        }
        prewarmRearmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    func upsertShortcut(_ shortcut: TerminalShortcut) {
        for existingShortcut in shortcuts where existingShortcut.id == shortcut.id {
            TerminalShortcutStore.deleteProtectedInputs(for: existingShortcut)
        }
        shortcuts.removeAll { $0.id == shortcut.id }
        shortcuts.insert(shortcut.normalized, at: 0)
        persistShortcuts()
    }

    private func persistShortcuts() {
        shortcuts = Array(shortcuts.map(\.normalized).filter(\.isPlayable).prefix(24))
        TerminalShortcutStore.save(shortcuts)
    }

    private func trackQuickPaths(for tab: TerminalSession) {
        guard case .localShell = tab.launchConfiguration else { return }
        recordQuickPath(tab.currentDirectory, for: tab)
        quickPathCancellables[tab.id] = tab.$currentDirectory
            .dropFirst()
            .sink { [weak self, weak tab] directory in
                guard let self, let tab else { return }
                self.recordQuickPath(directory, for: tab)
                // 选中标签的目录变了 → 新标签的继承目录随之改变，按新目录重排预热会话。
                if tab.id == self.selectedID {
                    self.refreshPrewarmIfStale()
                }
            }
    }

    private func recordQuickPath(_ directory: String?, for tab: TerminalSession) {
        guard let path = TerminalWorkingDirectory.normalizedExistingDirectory(directory) else { return }
        // 已拉黑的路径不再自动记录，杜绝「删了又因为再次 cd 冒出来」。
        guard !blacklistedQuickPaths.contains(path) else { return }
        guard lastRecordedQuickPathByTab[tab.id] != path else { return }
        lastRecordedQuickPathByTab[tab.id] = path
        quickPathRecords = TerminalQuickPathStore.record(directory: path, in: quickPathRecords)
        scheduleQuickPathSave()
    }

    func removeQuickPath(_ path: String) {
        guard let normalizedPath = TerminalWorkingDirectory.normalizedExistingDirectory(path) ?? path.nonEmptyTrimmed else {
            return
        }
        quickPathRecords.removeAll { $0.path == normalizedPath }
        scheduleQuickPathSave()
    }

    func flushQuickPathRecordsForTests() {
        flushPendingQuickPathSave()
    }

    private func scheduleQuickPathSave() {
        pendingQuickPathSaveWorkItem?.cancel()
        let records = quickPathRecords
        let workItem = DispatchWorkItem {
            TerminalQuickPathStore.saveAsync(records)
        }
        pendingQuickPathSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func flushPendingQuickPathSave() {
        pendingQuickPathSaveWorkItem?.cancel()
        pendingQuickPathSaveWorkItem = nil
        TerminalQuickPathStore.save(quickPathRecords)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
