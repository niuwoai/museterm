import AppKit
import Combine
import Darwin
import Foundation

enum TerminalLaunchConfiguration: Equatable {
    case localShell(startDirectory: String? = nil)
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
        guard case .localShell(let startDirectory) = self else { return nil }
        return startDirectory
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

enum TerminalCommandLifecycleState: String, Codable, Equatable {
    case running
    case succeeded
    case failed
    case interrupted
    case superseded
    case completedUnknownStatus = "completed_unknown_status"

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

    let id = UUID()
    let sequence: Int
    let createdAt = Date()
    let launchConfiguration: TerminalLaunchConfiguration

    @Published var title: String
    @Published var currentDirectory: String?
    @Published private(set) var shellName: String?
    @Published var state: State = .running
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var isPlayingShortcut = false
    @Published private(set) var fileTransferStatus: TerminalFileTransferStatus?
    @Published private(set) var commandBlocks: [TerminalCommandBlock] = []
    @Published private(set) var historySearchSnapshot = ""
    @Published private(set) var hasUnreadAttention = false

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
    weak var attentionReporter: TerminalAttentionReporting?

    init(sequence: Int, launchConfiguration: TerminalLaunchConfiguration = .localShell()) {
        self.sequence = sequence
        self.launchConfiguration = launchConfiguration
        title = launchConfiguration.connectionLabel ?? L10n.format("tab.default_title", sequence)
        currentDirectory = launchConfiguration.localStartDirectory
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

    func startProcessIfNeeded() {
        controller.ensureProcessStarted()
    }

    var canManuallyReconnectSSH: Bool {
        guard case .ssh = launchConfiguration,
              case .exited = state else {
            return false
        }
        return !hasRunningProcess
    }

    func reconnectSSH() {
        guard canManuallyReconnectSSH else { return }
        controller.reconnectSSH()
    }

    func markUnreadAttention() {
        guard !hasUnreadAttention else { return }
        hasUnreadAttention = true
    }

    func clearUnreadAttention() {
        guard hasUnreadAttention else { return }
        hasUnreadAttention = false
    }

    func reportBellAttention() {
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .bell)
    }

    func reportProcessExitAttention(exitCode: Int32?) {
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .processExited(exitCode))
    }

    func terminate() {
        cancelRecording()
        controller.terminate()
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
        return recorder?.finish(title: title, finishedAt: finishedAt)
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

    func startShellIntegratedCommand(command: String, historySnapshot: String) {
        startCommand(
            command: command,
            startSource: .shellIntegration,
            historySnapshot: historySnapshot
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
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
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

                let bytes = event.resolvedBytes(cache: &protectedBytesCache)
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
        self.activeCommandBlockID = nil
        activeCommandOutputStartIndex = historySnapshot.count
        attentionReporter?.terminalSession(self, didProduceAttentionEvent: .commandFinished(finishedBlock))
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
        historySnapshot: String
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
                activeCommandOutputStartIndex = historySnapshot.count
                pendingCommandBytes.removeAll(keepingCapacity: true)
                return
            }

            finishActiveCommand(
                exitCode: nil,
                completionSource: .superseded,
                historySnapshot: historySnapshot
            )
        }

        let block = TerminalCommandBlock(
            id: UUID(),
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
            completionSource: nil
        )
        commandBlocks.append(block)
        if commandBlocks.count > maxCommandBlocks {
            commandBlocks.removeFirst(commandBlocks.count - maxCommandBlocks)
        }
        activeCommandBlockID = block.id
        activeCommandOutputStartIndex = historySnapshot.count
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
}

protocol TerminalTabCloseConfirming {
    func shouldClose(tab: TerminalSession) -> Bool
}

struct SystemTerminalTabCloseConfirmer: TerminalTabCloseConfirming {
    private static let skipRunningTabCloseConfirmationKey = "terminal.skipRunningTabCloseConfirmation"

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

final class TerminalWorkspace: ObservableObject {
    @Published private(set) var tabs: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?
    @Published private(set) var shortcuts: [TerminalShortcut] = TerminalShortcutStore.load()
    weak var attentionReporter: TerminalAttentionReporting? {
        didSet {
            tabs.forEach { $0.attentionReporter = attentionReporter }
            preparedTab?.attentionReporter = attentionReporter
        }
    }
    // 最后一个标签被关闭后触发；宿主窗口据此关闭自身，未绑定时工作区保持空标签状态。
    var onAllTabsClosed: (() -> Void)?

    private let automaticallyStartProcesses: Bool
    private let tabCloseConfirmer: TerminalTabCloseConfirming
    private var nextSequence = 1
    private var preparedTab: TerminalSession?
    private var isPreparingNextTab = false
    private var lastShortcutNewTabUptime: TimeInterval = -.infinity
    private var lastShortcutNewTabEventTimestamp: TimeInterval?
    private var lastShortcutCloseTabUptime: TimeInterval = -.infinity
    private var lastShortcutCloseTabEventTimestamp: TimeInterval?
    private var isClosingTab = false

    init(
        automaticallyStartProcesses: Bool = true,
        tabCloseConfirmer: TerminalTabCloseConfirming = SystemTerminalTabCloseConfirmer()
    ) {
        self.automaticallyStartProcesses = automaticallyStartProcesses
        self.tabCloseConfirmer = tabCloseConfirmer
        newTab()
    }

    deinit {
        preparedTab?.terminate()
    }

    var selectedTab: TerminalSession? {
        guard let selectedID else { return tabs.first }
        return tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func newTab(startDirectory: String? = nil) {
        let resolvedStartDirectory = resolvedNewLocalTabStartDirectory(explicitStartDirectory: startDirectory)
        let tab = resolvedStartDirectory == nil
            ? takePreparedTab()
            : makeTab(launchConfiguration: .localShell(startDirectory: resolvedStartDirectory))
        tab.attentionReporter = attentionReporter
        tabs.append(tab)
        selectedID = tab.id
        tab.clearUnreadAttention()
        if automaticallyStartProcesses {
            DispatchQueue.main.async {
                tab.startProcessIfNeeded()
            }
        }
        schedulePrepareNextTab()
    }

    private func resolvedNewLocalTabStartDirectory(explicitStartDirectory: String?) -> String? {
        if explicitStartDirectory != nil {
            return TerminalWorkingDirectory.normalizedExistingDirectory(explicitStartDirectory)
        }

        guard let selectedTab,
              case .localShell(let launchStartDirectory) = selectedTab.launchConfiguration else {
            return nil
        }

        return TerminalWorkingDirectory.normalizedExistingDirectory(selectedTab.currentDirectory)
            ?? TerminalWorkingDirectory.normalizedExistingDirectory(launchStartDirectory)
    }

    func openSSH(profile: SSHConnectionProfile) {
        let tab = makeTab(launchConfiguration: .ssh(profile))
        tab.attentionReporter = attentionReporter
        tabs.append(tab)
        selectedID = tab.id
        tab.clearUnreadAttention()
        if automaticallyStartProcesses {
            DispatchQueue.main.async {
                tab.startProcessIfNeeded()
            }
        }
    }

    func saveSnapshot() throws {
        let snapshotTabs = tabs.map { tab -> TerminalWorkspaceSnapshot.Tab in
            switch tab.launchConfiguration {
            case .localShell(let startDirectory):
                return .local(directory: tab.currentDirectory ?? startDirectory)
            case .ssh(let profile):
                return .ssh(profile: profile)
            }
        }

        guard !snapshotTabs.isEmpty else {
            throw TerminalWorkspaceSnapshotError.emptyWorkspace
        }

        let selectedIndex = selectedTab.flatMap { selected in
            tabs.firstIndex { $0.id == selected.id }
        } ?? 0

        let snapshot = TerminalWorkspaceSnapshot(
            selectedIndex: min(max(selectedIndex, 0), snapshotTabs.count - 1),
            tabs: snapshotTabs
        )
        try TerminalWorkspaceSnapshotStore.save(snapshot)
    }

    func restoreSnapshot() throws {
        let snapshot = try TerminalWorkspaceSnapshotStore.load()
        guard !snapshot.tabs.isEmpty else {
            throw TerminalWorkspaceSnapshotError.emptyWorkspace
        }

        let restoredTabs = try snapshot.tabs.map { tabSnapshot -> TerminalSession in
            switch tabSnapshot.kind {
            case .local:
                return makeTab(
                    launchConfiguration: .localShell(
                        startDirectory: TerminalWorkingDirectory.normalizedExistingDirectory(tabSnapshot.localDirectory)
                    )
                )
            case .ssh:
                guard let profile = tabSnapshot.sshProfile else {
                    throw TerminalWorkspaceSnapshotError.unsupportedTab
                }
                return makeTab(launchConfiguration: .ssh(profile.normalized))
            }
        }

        preparedTab?.terminate()
        preparedTab = nil
        isPreparingNextTab = false
        tabs.forEach { $0.terminate() }
        tabs = restoredTabs
        tabs.forEach { $0.attentionReporter = attentionReporter }

        let selectedIndex = min(max(snapshot.selectedIndex, 0), tabs.count - 1)
        selectedID = tabs[selectedIndex].id
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

    @discardableResult
    func closeSelectedTabFromShortcut(eventTimestamp: TimeInterval? = nil) -> Bool {
        guard !isClosingTab else { return false }
        guard shouldHandleCloseTabShortcut(eventTimestamp: eventTimestamp) else { return false }
        return closeSelectedTab()
    }

    func select(_ tab: TerminalSession) {
        selectedID = tab.id
        tab.clearUnreadAttention()
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
    func close(_ tab: TerminalSession) -> Bool {
        guard !isClosingTab else { return false }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        isClosingTab = true
        defer { isClosingTab = false }

        guard tabCloseConfirmer.shouldClose(tab: tab) else { return false }

        tab.terminate()
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            selectedID = nil
            onAllTabsClosed?()
            return true
        }

        if selectedID == tab.id {
            let fallbackIndex = min(index, tabs.count - 1)
            selectedID = tabs[fallbackIndex].id
            tabs[fallbackIndex].clearUnreadAttention()
        }

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

    func startZModemUpload(fileURLs: [URL]) {
        selectedTab?.startZModemUpload(fileURLs: fileURLs)
        objectWillChange.send()
    }

    func startZModemDownload(remotePath: String, destinationFile: URL) {
        selectedTab?.startZModemDownload(remotePath: remotePath, destinationFile: destinationFile)
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
        shortcuts.filter { $0.id == id }.forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == id }
        persistShortcuts()
    }

    func editableShortcutsText() -> String {
        TerminalShortcutStore.editableText(for: shortcuts)
    }

    func saveEditableShortcutsText(_ text: String) throws {
        let edited = try TerminalShortcutStore.decodeEditableText(text)
        for shortcut in shortcuts where edited.contains(where: { $0.id == shortcut.id }) == false {
            TerminalShortcutStore.deleteProtectedInputs(for: shortcut)
        }
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

    func sendToolInput(to selector: String?, bytes: [UInt8]) throws -> TerminalSession {
        let tab = try toolTab(matching: selector)
        tab.startProcessIfNeeded()
        try tab.controller.sendToolInput(bytes: bytes)
        selectedID = tab.id
        return tab
    }

    private func toolTab(matching selector: String?) throws -> TerminalSession {
        let cleaned = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty, cleaned != "selected" else {
            if let selectedTab { return selectedTab }
            if let first = tabs.first { return first }
            throw TerminalToolError.tabNotFound("selected")
        }

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

    private func takePreparedTab() -> TerminalSession {
        if let preparedTab {
            self.preparedTab = nil
            preparedTab.attentionReporter = attentionReporter
            return preparedTab
        }

        return makeTab()
    }

    private func makeTab(launchConfiguration: TerminalLaunchConfiguration = .localShell()) -> TerminalSession {
        let tab = TerminalSession(sequence: nextSequence, launchConfiguration: launchConfiguration)
        tab.attentionReporter = attentionReporter
        nextSequence += 1
        return tab
    }

    private func schedulePrepareNextTab() {
        guard automaticallyStartProcesses else { return }
        guard preparedTab == nil, !isPreparingNextTab else { return }
        isPreparingNextTab = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.prepareNextTab()
        }
    }

    private func prepareNextTab() {
        defer { isPreparingNextTab = false }
        guard preparedTab == nil else { return }

        let tab = makeTab()
        tab.prepareController()
        preparedTab = tab
    }

    private func upsertShortcut(_ shortcut: TerminalShortcut) {
        shortcuts.filter { $0.id == shortcut.id }.forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == shortcut.id }
        shortcuts.insert(shortcut.normalized, at: 0)
        persistShortcuts()
    }

    private func persistShortcuts() {
        shortcuts = Array(shortcuts.map(\.normalized).filter(\.isPlayable).prefix(24))
        TerminalShortcutStore.save(shortcuts)
    }
}
