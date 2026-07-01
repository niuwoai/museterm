import AppKit
import Darwin
import SwiftTerm
import SwiftUI

private struct LocalShellLaunchDescriptor {
    let executable: String
    let args: [String]
    let execName: String
    let environment: [String]
    let shellName: String
}

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: TerminalPreferences
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let controller = session.controller
        controller.setActive(isActive)
        DispatchQueue.main.async {
            controller.ensureProcessStarted()
            if isActive {
                controller.focusTerminal()
            }
        }
        return controller.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.controller.layoutTerminalViews()
        session.controller.apply(preferences: preferences)
        session.controller.setActive(isActive)
        DispatchQueue.main.async {
            session.controller.ensureProcessStarted()
            if isActive {
                session.controller.focusTerminal()
                session.controller.invalidateDisplay()
            }
        }
    }
}

final class TerminalHostController: NSObject, LocalProcessTerminalViewDelegate {
    private static let minimumStartSize = CGSize(width: 120, height: 80)
    private static let uploadReadyMarker = "__MUSETERM_ZMODEM_UPLOAD_READY__"
    private static let uploadMissingMarker = "__MUSETERM_ZMODEM_UPLOAD_MISSING__"
    private static let downloadReadyMarker = "__MUSETERM_ZMODEM_DOWNLOAD_READY__"
    private static let downloadMissingMarker = "__MUSETERM_ZMODEM_DOWNLOAD_MISSING__"
    let container = NSView(frame: .zero)
    private let visualEffectView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let terminalLeadingMarginView = NSView(frame: .zero)
    private let terminalTrailingMarginView = NSView(frame: .zero)
    private let terminalView = FocusableLocalProcessTerminalView(frame: .zero)
    private let startupCoverView = NSView(frame: .zero)
    private weak var session: TerminalSession?
    private var didStart = false
    private var pendingStart = false
    private var pendingStartWorkItem: DispatchWorkItem?
    private var startupPromptPollWorkItem: DispatchWorkItem?
    private var startupHardDeadline: TimeInterval = 0
    private var startupLastOutputUptime: TimeInterval = 0
    private var startupFirstContentUptime: TimeInterval = 0
    private var startupRedrawCount = 0
    private var didRunStartupPromptRedraw = false
    private var didReceiveProcessInput = false
    private var didConfigureMetal = false
    private var lastAppliedPreferences: TerminalPreferenceSignature?
    private var pendingZModemProbe: PendingZModemProbe?
    private var activeZModemTransfer: ZModemBridgeProcess?
    private let shellIntegrationParser = TerminalShellIntegrationParser()
    private var pendingShellIntegrationEvents: [TerminalShellIntegrationEvent] = []
    private weak var preferences: TerminalPreferences?
    private var pendingSafetyInputBytes: [UInt8] = []
    private let maxPendingSafetyInputBytes = 8_192

    init(session: TerminalSession) {
        self.session = session
        super.init()
        configureViews()
    }

    func apply(preferences: TerminalPreferences) {
        self.preferences = preferences
        layoutTerminalViews()
        let signature = TerminalPreferenceSignature(preferences: preferences)
        guard signature != lastAppliedPreferences else { return }
        lastAppliedPreferences = signature

        visualEffectView.isHidden = !preferences.glassEnabled
        visualEffectView.material = preferences.glassMaterial.nsMaterial
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.alphaValue = CGFloat(preferences.glassOpacity)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = preferences.skin.caret
            .withOpacity(CGFloat(preferences.tintOpacity))
            .cgColor

        let background = preferences.skin.terminalBackground.withOpacity(CGFloat(preferences.terminalOpacity))
        terminalLeadingMarginView.layer?.backgroundColor = background.cgColor
        terminalTrailingMarginView.layer?.backgroundColor = background.cgColor
        // 遮罩用不透明的终端背景色，保证完全遮住底下的文字（背景本身可能半透明）。
        startupCoverView.layer?.backgroundColor = preferences.skin.terminalBackground.cgColor
        terminalView.nativeForegroundColor = preferences.skin.terminalForeground
        terminalView.nativeBackgroundColor = background
        terminalView.layer?.backgroundColor = background.cgColor
        terminalView.selectedTextBackgroundColor = preferences.skin.caret.withOpacity(0.22)
        terminalView.caretColor = preferences.skin.caret
        terminalView.font = preferences.terminalFont
        terminalView.installColors(preferences.colorPalette.swiftTermColors)
        terminalView.lineSpacing = CGFloat(preferences.lineHeight)
        terminalView.optionAsMetaKey = preferences.optionAsMeta
        terminalView.allowMouseReporting = preferences.mouseReporting
        applyCursorStyle(shape: preferences.cursorShape, blink: preferences.cursorBlink)
        terminalView.customBlockGlyphs = true
        terminalView.antiAliasCustomBlockGlyphs = true
        terminalView.useBrightColors = true

        configureMetalIfNeeded()

        requestTerminalRepaint()
    }

    func layoutTerminalViews() {
        visualEffectView.frame = container.bounds
        tintView.frame = container.bounds
        let horizontalInset = max(4, ceil(terminalView.font.pointSize * 0.36))
        let marginWidth = min(horizontalInset, container.bounds.width / 2)
        terminalLeadingMarginView.frame = CGRect(
            x: 0,
            y: 0,
            width: marginWidth,
            height: container.bounds.height
        )
        terminalTrailingMarginView.frame = CGRect(
            x: max(0, container.bounds.width - marginWidth),
            y: 0,
            width: marginWidth,
            height: container.bounds.height
        )
        terminalView.frame = container.bounds
        terminalView.frame.origin.x += marginWidth
        terminalView.frame.size.width = max(0, terminalView.frame.width - marginWidth * 2)
        startupCoverView.frame = container.bounds
        schedulePendingProcessStartIfReady()
    }

    func terminate() {
        terminalView.terminate()
    }

    func ensureProcessStarted() {
        if canStartProcess {
            pendingStart = true
            schedulePendingProcessStartIfReady()
        } else {
            pendingStart = true
            pendingStartWorkItem?.cancel()
        }
    }

    func focusTerminal() {
        terminalView.requestFocus()
    }

    func setActive(_ isActive: Bool) {
        container.alphaValue = 1
        container.isHidden = !isActive
        terminalView.isHidden = !isActive
        terminalView.layer?.isHidden = !isActive
    }

    func invalidateDisplay() {
        terminalView.needsDisplay = true
        terminalView.layer?.setNeedsDisplay()
    }

    private func applyCursorStyle(shape: TerminalCursorShape, blink: Bool) {
        guard let terminal = terminalView.terminal else { return }
        let style: CursorStyle
        switch shape {
        case .block:
            style = blink ? .blinkBlock : .steadyBlock
        case .bar:
            style = blink ? .blinkBar : .steadyBar
        case .underline:
            style = blink ? .blinkUnderline : .steadyUnderline
        }
        // 必须走 setCursorStyle：它会更新 terminal.options.cursorStyle（Metal 渲染器据此
        // 画光标）以及 caretView（非 Metal 路径）。仅调 cursorStyleChanged 只改 caretView，
        // 在 Metal 开启时对屏幕上的光标无效。
        terminal.setCursorStyle(style)
    }

    // Metal 渲染器是按需重绘（MTKView isPaused=true），颜色/光标/字体等设置变更不会自动
    // 触发它重绘，于是“改了设置不及时生效”。这里在应用设置后强制刷新一次：CoreText 路径
    // 用 needsDisplay；Metal 路径借 metalScaleFactorOverride 的 didSet 触发 requestMetalDisplay，
    // 最终落回 nil（默认 backing scale），所以画面比例不变，只是被重画一次。
    private func requestTerminalRepaint() {
        terminalView.needsDisplay = true
        guard terminalView.isUsingMetalRenderer else { return }
        terminalView.metalScaleFactorOverride = 1
        terminalView.metalScaleFactorOverride = nil
    }

    func toolSnapshot(
        index: Int,
        isSelected: Bool,
        maxHistoryCharacters: Int
    ) -> TerminalToolTabSnapshot {
        let recentCommandBlocks = Array(session?.commandBlocks.suffix(50) ?? [])
        return TerminalToolTabSnapshot(
            id: session?.id.uuidString ?? UUID().uuidString,
            index: index,
            title: session?.tabTitle ?? "",
            subtitle: session?.tabSubtitle,
            currentDirectory: session?.currentDirectory,
            shellName: session?.shellName,
            isSelected: isSelected,
            state: session?.toolStateText ?? "unknown",
            columns: terminalView.terminal?.cols ?? 0,
            rows: terminalView.terminal?.rows ?? 0,
            screen: visibleScreenText(),
            history: String(fullHistoryText().suffix(maxHistoryCharacters)),
            commandDiagnostics: TerminalToolCommandDiagnosticsSnapshot(
                diagnostics: CommandBlockDiagnostics(blocks: recentCommandBlocks)
            ),
            commandBlocks: recentCommandBlocks.map { block in
                TerminalToolCommandBlockSnapshot(
                    id: block.id.uuidString,
                    command: block.command,
                    workingDirectory: block.workingDirectory,
                    startedAt: block.startedAt,
                    endedAt: block.endedAt,
                    exitCode: block.exitCode,
                    commandLifecycleState: block.commandLifecycleState.rawValue,
                    commandRiskLevel: block.commandRiskProfile.level.rawValue,
                    commandRiskReasons: block.commandRiskProfile.reasons.map(\.rawValue),
                    commandStartSource: block.commandStartSource?.rawValue,
                    completionSource: block.completionSource?.rawValue,
                    commandBoundaryConfidence: block.commandBoundaryConfidence.rawValue,
                    commandBoundaryReasons: block.commandBoundaryReasons.map(\.rawValue),
                    durationMilliseconds: block.durationMilliseconds,
                    outputTail: block.outputTail,
                    outputCharacterCount: block.outputCharacterCount,
                    outputSummary: block.outputSummary,
                    isInteractive: block.isInteractive
                )
            },
            updatedAt: Date()
        )
    }

    func sendToolInput(bytes: [UInt8]) throws {
        guard didStart, terminalView.process.running else {
            throw TerminalToolError.processUnavailable
        }
        sendProcessInput(bytes: bytes)
    }

    func sendProcessInput(bytes: [UInt8]) {
        terminalView.send(source: terminalView, data: bytes[...])
    }

    var isProcessRunning: Bool {
        didStart && terminalView.process.running
    }

    func startZModemUpload(fileURLs: [URL]) {
        guard didStart, terminalView.process.running else {
            reportFileTransferFailure(kind: .upload, reason: L10n.string("file_transfer.error.process_unavailable"))
            return
        }
        guard !fileURLs.isEmpty else {
            reportFileTransferFailure(kind: .upload, reason: L10n.string("file_transfer.error.no_file"))
            return
        }
        guard let toolURL = ZModemLocalTool.executable(named: "sz") else {
            reportLocalToolMissing(kind: .upload, toolName: "sz")
            return
        }

        cancelActiveZModemTransfer()
        let probe = PendingZModemProbe(
            kind: .upload,
            readyMarker: Self.uploadReadyMarker,
            missingMarker: Self.uploadMissingMarker,
            startLocalTransfer: { [weak self] initialRemoteBytes in
                self?.startLocalZModemTransfer(
                    kind: .upload,
                    executableURL: toolURL,
                    arguments: ["-b"] + fileURLs.map(\.path),
                    currentDirectory: nil,
                    initialRemoteBytes: initialRemoteBytes
                )
            }
        )
        pendingZModemProbe = probe
        session?.updateFileTransferStatus(.checkingRemote(kind: .upload))
        sendProcessInput(bytes: Array(remoteUploadProbeCommand.utf8))
        scheduleZModemProbeTimeout(probeID: probe.id)
    }

    func startZModemDownload(remotePath: String, destinationFile: URL) {
        guard didStart, terminalView.process.running else {
            reportFileTransferFailure(kind: .download, reason: L10n.string("file_transfer.error.process_unavailable"))
            return
        }
        let cleanedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedRemotePath.isEmpty else {
            reportFileTransferFailure(kind: .download, reason: L10n.string("file_transfer.error.no_remote_path"))
            return
        }
        guard let toolURL = ZModemLocalTool.executable(named: "rz") else {
            reportLocalToolMissing(kind: .download, toolName: "rz")
            return
        }

        let downloadPlan: ZModemDownloadPlan
        do {
            downloadPlan = try ZModemDownloadPlan(remotePath: cleanedRemotePath, destinationFile: destinationFile)
        } catch {
            reportFileTransferFailure(kind: .download, reason: error.localizedDescription)
            return
        }

        cancelActiveZModemTransfer()
        let probe = PendingZModemProbe(
            kind: .download,
            readyMarker: Self.downloadReadyMarker,
            missingMarker: Self.downloadMissingMarker,
            startLocalTransfer: { [weak self] initialRemoteBytes in
                self?.startLocalZModemTransfer(
                    kind: .download,
                    executableURL: toolURL,
                    arguments: ["-E"],
                    currentDirectory: downloadPlan.temporaryDirectory,
                    initialRemoteBytes: initialRemoteBytes,
                    downloadPlan: downloadPlan
                )
            }
        )
        pendingZModemProbe = probe
        session?.updateFileTransferStatus(.checkingRemote(kind: .download))
        sendProcessInput(bytes: Array(remoteDownloadProbeCommand(remotePath: cleanedRemotePath).utf8))
        scheduleZModemProbeTimeout(probeID: probe.id)
    }

    var terminalEchoEnabled: Bool {
        terminalView.terminalEchoEnabled
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        session?.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        session?.currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        session?.finishActiveCommand(
            exitCode: exitCode,
            completionSource: .processExit,
            historySnapshot: fullHistoryText()
        )
        session?.state = .exited(exitCode)
    }

    private func configureViews() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 0
        container.layer?.masksToBounds = true

        visualEffectView.autoresizingMask = [.width, .height]
        container.addSubview(visualEffectView)

        tintView.autoresizingMask = [.width, .height]
        container.addSubview(tintView)

        terminalLeadingMarginView.wantsLayer = true
        terminalLeadingMarginView.autoresizingMask = [.height]
        container.addSubview(terminalLeadingMarginView)

        terminalTrailingMarginView.wantsLayer = true
        terminalTrailingMarginView.autoresizingMask = [.minXMargin, .height]
        container.addSubview(terminalTrailingMarginView)

        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        terminalView.wantsLayer = true
        terminalView.onNeedsFocus = { [weak self] in
            self?.focusTerminal()
        }
        terminalView.onReadyForProcessStart = { [weak self] in
            self?.schedulePendingProcessStartIfReady()
        }
        terminalView.onStableTerminalResize = { [weak self] cols, rows in
            self?.applyStablePTYSize(newCols: cols, newRows: rows)
        }
        terminalView.onProcessInputSent = { [weak self] in
            self?.didReceiveProcessInput = true
        }
        terminalView.onTerminalTitle = { [weak self] title in
            guard let self else { return }
            self.setTerminalTitle(source: self.terminalView, title: title)
        }
        terminalView.onCurrentDirectory = { [weak self] directory in
            guard let self else { return }
            self.hostCurrentDirectoryUpdate(source: self.terminalView, directory: directory)
        }
        terminalView.shouldRecordInput = { [weak self] in
            guard let session = self?.session else { return false }
            return session.isRecording && !session.isPlayingShortcut
        }
        terminalView.onSendToProcess = { [weak self] data, echoEnabled in
            guard let self else { return true }
            guard self.approveProcessInputIfNeeded(data: data, echoEnabled: echoEnabled) else {
                return false
            }
            guard self.activeZModemTransfer == nil, self.pendingZModemProbe == nil else {
                return true
            }
            self.session?.recordInputIfNeeded(data: data, echoEnabled: echoEnabled)
            self.session?.observeProcessInput(
                data: data,
                echoEnabled: echoEnabled,
                historySnapshot: self.fullHistoryText()
            )
            self.updatePendingSafetyInput(data: data, echoEnabled: echoEnabled)
            return true
        }
        terminalView.onReceivedProcessData = { [weak self] data in
            guard let self else { return false }
            self.handleProcessOutputForShellIntegration(data)
            return self.handleProcessOutputForZModem(data)
        }
        terminalView.onProcessOutputCommitted = { [weak self] in
            guard let self else { return }
            let historySnapshot = self.fullHistoryText()
            self.flushPendingShellIntegrationEvents(historySnapshot: historySnapshot)
            self.session?.observeProcessOutput(historySnapshot: historySnapshot)
        }
        container.addSubview(terminalView)

        // 启动期遮罩：盖在终端最上层，新建标签时遮住首屏 PS1 的抖动/重绘/清屏，
        // 待画面稳定后淡出，避免用户看到“先两条再变一条”的闪烁。
        startupCoverView.wantsLayer = true
        startupCoverView.autoresizingMask = [.width, .height]
        startupCoverView.isHidden = true
        startupCoverView.layer?.opacity = 1
        container.addSubview(startupCoverView)

        layoutTerminalViews()
    }

    private func handleProcessOutputForZModem(_ data: ArraySlice<UInt8>) -> Bool {
        noteStartupOutputActivity()
        if let activeZModemTransfer {
            activeZModemTransfer.acceptRemoteData(Array(data))
            return true
        }

        guard let pendingZModemProbe else { return false }
        let bytes = Array(data)
        if let result = pendingZModemProbe.acceptRemoteProbeData(bytes) {
            self.pendingZModemProbe = nil
            switch result {
            case .ready(let initialRemoteBytes):
                pendingZModemProbe.startLocalTransfer(initialRemoteBytes)
            case .missing:
                reportRemoteToolMissing(kind: pendingZModemProbe.kind)
            }
        }
        return true
    }

    private func handleProcessOutputForShellIntegration(_ data: ArraySlice<UInt8>) {
        guard activeZModemTransfer == nil, pendingZModemProbe == nil else { return }
        pendingShellIntegrationEvents.append(contentsOf: shellIntegrationParser.accept(data))
    }

    private func flushPendingShellIntegrationEvents(historySnapshot: String) {
        guard !pendingShellIntegrationEvents.isEmpty else { return }
        let events = pendingShellIntegrationEvents
        pendingShellIntegrationEvents.removeAll(keepingCapacity: true)

        for event in events {
            switch event {
            case .commandStarted(let command):
                session?.startShellIntegratedCommand(
                    command: command,
                    historySnapshot: historySnapshot
                )
            case .commandFinished(let exitCode):
                session?.finishActiveCommand(
                    exitCode: exitCode,
                    completionSource: .shellIntegration,
                    historySnapshot: historySnapshot
                )
            case .shellDetected(let shellName):
                session?.updateShellName(shellName)
            }
        }
    }

    private func approveProcessInputIfNeeded(data: [UInt8], echoEnabled: Bool) -> Bool {
        guard echoEnabled, activeZModemTransfer == nil, pendingZModemProbe == nil else { return true }
        guard let preferences else { return true }

        let safetyPolicy = session?.safetyPolicy ?? .inherit
        let shouldConfirmMultilinePaste = safetyPolicy.resolves(globalValue: preferences.confirmMultilinePaste)
        let shouldConfirmDangerousCommands = safetyPolicy.resolves(globalValue: preferences.confirmDangerousCommands)

        if shouldConfirmMultilinePaste,
           let text = String(bytes: data, encoding: .utf8),
           SafetyInputAnalyzer.isMultilinePaste(text) {
            guard confirmMultilinePaste(text) else { return false }
        }

        guard shouldConfirmDangerousCommands else { return true }
        guard let command = pendingCommandCandidate(afterAppending: data) else { return true }
        guard let rule = SafetyInputAnalyzer.dangerousRule(
            for: command,
            customRulesText: preferences.customDangerousCommandRules
        ) else { return true }
        return confirmDangerousCommand(command, rule: rule)
    }

    private func pendingCommandCandidate(afterAppending data: [UInt8]) -> String? {
        guard data.contains(where: { $0 == 0x0D || $0 == 0x0A }) else { return nil }
        var bytes = pendingSafetyInputBytes
        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                break
            }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updatePendingSafetyInput(data: [UInt8], echoEnabled: Bool) {
        guard echoEnabled else {
            pendingSafetyInputBytes.removeAll(keepingCapacity: true)
            return
        }

        for byte in data {
            switch byte {
            case 0x0D, 0x0A, 0x03:
                pendingSafetyInputBytes.removeAll(keepingCapacity: true)
            case 0x7F, 0x08:
                if !pendingSafetyInputBytes.isEmpty {
                    pendingSafetyInputBytes.removeLast()
                }
            default:
                if byte == 0x09 || byte >= 0x20 {
                    pendingSafetyInputBytes.append(byte)
                    if pendingSafetyInputBytes.count > maxPendingSafetyInputBytes {
                        pendingSafetyInputBytes.removeFirst(pendingSafetyInputBytes.count - maxPendingSafetyInputBytes)
                    }
                }
            }
        }
    }

    private func confirmMultilinePaste(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SafetyInputAnalyzer.multilinePasteConfirmationTitle(for: text)
        alert.informativeText = SafetyInputAnalyzer.multilinePasteConfirmationMessage(for: text)
        alert.addButton(withTitle: SafetyInputAnalyzer.multilinePastePrimaryActionTitle(for: text))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        alert.accessoryView = SafetyPreviewTextView(text: SafetyInputAnalyzer.preview(text))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDangerousCommand(_ command: String, rule: SafetyDangerousCommandRule) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = session?.environment == .production ? .critical : .warning
        alert.messageText = L10n.string("safety.dangerous.title")
        alert.informativeText = L10n.format(
            "safety.dangerous.message",
            rule.localizedName,
            session?.environment.name ?? TerminalEnvironmentKind.local.name
        )
        alert.addButton(withTitle: L10n.string("safety.action.run_anyway"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        alert.accessoryView = SafetyPreviewTextView(text: command)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startLocalZModemTransfer(
        kind: TerminalFileTransferKind,
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        initialRemoteBytes: [UInt8],
        downloadPlan: ZModemDownloadPlan? = nil
    ) {
        do {
            let transfer = try ZModemBridgeProcess(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectory: currentDirectory,
                onOutput: { [weak self] output in
                    DispatchQueue.main.async {
                        guard let self, self.terminalView.process.running else { return }
                        self.terminalView.send(source: self.terminalView, data: output[...])
                    }
                },
                onProgress: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.session?.updateFileTransferStatus(.transferring(kind: kind, progress: progress))
                    }
                },
                onExit: { [weak self] exitCode in
                    DispatchQueue.main.async {
                        self?.finishZModemTransfer(kind: kind, exitCode: exitCode, downloadPlan: downloadPlan)
                    }
                }
            )
            activeZModemTransfer = transfer
            session?.updateFileTransferStatus(.transferring(kind: kind, progress: nil))
            if !initialRemoteBytes.isEmpty {
                transfer.acceptRemoteData(initialRemoteBytes)
            }
        } catch {
            reportFileTransferFailure(kind: kind, reason: error.localizedDescription)
        }
    }

    private func finishZModemTransfer(kind: TerminalFileTransferKind, exitCode: Int32, downloadPlan: ZModemDownloadPlan?) {
        activeZModemTransfer = nil
        if exitCode == 0 {
            do {
                try downloadPlan?.moveDownloadedFileToDestination()
                session?.updateFileTransferStatus(.completed(kind: kind))
                terminalView.feed(text: "\n\(L10n.string(kind == .upload ? "file_transfer.upload.completed" : "file_transfer.download.completed"))\n")
            } catch {
                reportFileTransferFailure(kind: kind, reason: error.localizedDescription)
            }
            downloadPlan?.cleanup()
        } else {
            reportFileTransferFailure(kind: kind, reason: L10n.format("file_transfer.error.local_exit", exitCode))
            downloadPlan?.cleanup()
        }
    }

    private func cancelActiveZModemTransfer() {
        pendingZModemProbe = nil
        activeZModemTransfer?.terminate()
        activeZModemTransfer = nil
    }

    private func reportLocalToolMissing(kind: TerminalFileTransferKind, toolName: String) {
        let reason = L10n.format("file_transfer.error.local_tool_missing", toolName)
        reportFileTransferFailure(kind: kind, reason: reason)
        terminalView.feed(text: "\n\(reason)\n\(L10n.string("file_transfer.local_install"))\n")
    }

    private func reportRemoteToolMissing(kind: TerminalFileTransferKind) {
        let toolName = kind == .upload ? "rz" : "sz"
        let reason = L10n.format("file_transfer.error.remote_tool_missing", toolName)
        reportFileTransferFailure(kind: kind, reason: reason)
        terminalView.feed(text: "\n\(reason)\n\(L10n.string("file_transfer.remote_install"))\n")
    }

    private func reportFileTransferFailure(kind: TerminalFileTransferKind, reason: String) {
        session?.updateFileTransferStatus(.failed(kind: kind, reason: reason))
    }

    private func scheduleZModemProbeTimeout(probeID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pendingZModemProbe?.id == probeID else { return }
            let kind = self.pendingZModemProbe?.kind ?? .upload
            self.pendingZModemProbe = nil
            self.reportFileTransferFailure(kind: kind, reason: L10n.string("file_transfer.error.remote_probe_timeout"))
        }
    }

    private var remoteUploadProbeCommand: String {
        """
        if command -v rz >/dev/null 2>&1; then printf '\\n\(Self.uploadReadyMarker)\\n'; rz -E; else printf '\\n\(Self.uploadMissingMarker)\\n'; fi
        """
        + "\n"
    }

    private func remoteDownloadProbeCommand(remotePath: String) -> String {
        """
        if command -v sz >/dev/null 2>&1; then printf '\\n\(Self.downloadReadyMarker)\\n'; sz -e -- \(Self.shellQuoted(remotePath)); else printf '\\n\(Self.downloadMissingMarker)\\n'; fi
        """
        + "\n"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func startProcessIfNeeded() {
        guard !didStart else { return }
        pendingStart = false
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        didStart = true

        switch session?.launchConfiguration ?? .localShell() {
        case .localShell(let startDirectory):
            let descriptor = Self.localShellLaunchDescriptor()
            let currentDirectory = TerminalWorkingDirectory.normalizedExistingDirectory(startDirectory)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            session?.updateShellName(descriptor.shellName)
            // 先盖上遮罩，再启动进程：保证 shell 的第一条 PS1 输出抵达前画面已被遮住。
            beginStartupPromptDeduplication()
            terminalView.startProcess(
                executable: descriptor.executable,
                args: descriptor.args,
                environment: descriptor.environment,
                execName: descriptor.execName,
                currentDirectory: currentDirectory
            )
        case .ssh(let profile):
            do {
                let descriptor = try SSHConfigMaterializer.descriptor(for: profile)
                terminalView.startProcess(
                    executable: descriptor.executable,
                    args: descriptor.args,
                    environment: Self.environmentArray(shellPath: nil),
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                let startupCommands = [RemoteShellIntegration.shellProbeCommand]
                    + RemoteShellIntegration.startupCommands(for: profile)
                    + descriptor.startupCommands
                drainStartupCommands(startupCommands)
            } catch {
                terminalView.feed(text: L10n.format("ssh.error.launch_failed", error.localizedDescription) + "\n")
                session?.state = .exited(nil)
            }
        }
    }

    private func drainStartupCommands(_ commands: [String]) {
        guard !commands.isEmpty else { return }
        Task { [weak self] in
            for command in commands {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    guard let self, self.terminalView.process.running else { return }
                    self.terminalView.send(source: self.terminalView, data: Array((command + "\n").utf8)[...])
                }
            }
        }
    }

    private var canStartProcess: Bool {
        terminalView.window != nil
            && terminalView.bounds.width >= Self.minimumStartSize.width
            && terminalView.bounds.height >= Self.minimumStartSize.height
    }

    private func schedulePendingProcessStartIfReady() {
        pendingStartWorkItem?.cancel()
        guard pendingStart, canStartProcess else { return }
        let scheduledSize = terminalView.bounds.size
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingStart, self.canStartProcess else { return }
            guard self.terminalView.bounds.size == scheduledSize else {
                self.schedulePendingProcessStartIfReady()
                return
            }
            self.startProcessIfNeeded()
        }
        pendingStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func applyStablePTYSize(newCols: Int, newRows: Int) {
        guard terminalView.process.running else { return }
        var size = terminalView.getWindowSize()
        let _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: terminalView.process.childfd,
            windowSize: &size
        )
        // 启动期的窗口定型 resize 会向 shell 发 SIGWINCH 触发重绘（首个标签尤其晚），
        // 把它也算作“活动”，让遮罩继续盖住并等它引发的重绘安静后再判定，避免过早揭幕。
        noteStartupOutputActivity()
        sizeChanged(source: terminalView, newCols: newCols, newRows: newRows)
    }

    // 新建标签时，shell 打印 PS1 后常因启动期 SIGWINCH 或 p10k 实时提示符，把提示符
    // 在顶部重绘成多条。关键教训：绝不能在“输出还在抖动”时去发 ^L —— 那会和 WINCH 重绘
    // 互相打架（清一条又冒一条）。正确做法是全程用遮罩盖住首屏，等输出“安静”一段时间
    // （说明启动抖动已结束）再判断：若仍重复才发一次 ^L 清屏，再等它安静、确认干净后揭幕。
    private func beginStartupPromptDeduplication() {
        let now = ProcessInfo.processInfo.systemUptime
        didRunStartupPromptRedraw = false
        startupRedrawCount = 0
        startupLastOutputUptime = now
        startupFirstContentUptime = 0
        // 硬上限：无论如何最多盖这么久，避免极端情况下一直盖着空白。
        startupHardDeadline = now + 3.0
        showStartupCover()
        scheduleStartupPromptPoll(after: 0.12)
    }

    // 记录最近一次输出时刻，用于判断输出是否已经“安静”。^L 自身产生的输出也会刷新它，
    // 从而保证 ^L 之后会再等一轮安静、复检干净后才揭幕。
    private func noteStartupOutputActivity() {
        guard !didRunStartupPromptRedraw else { return }
        startupLastOutputUptime = ProcessInfo.processInfo.systemUptime
    }

    private func scheduleStartupPromptPoll(after delay: TimeInterval) {
        startupPromptPollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runStartupPromptPoll()
        }
        startupPromptPollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runStartupPromptPoll() {
        // 输出安静多久算“启动抖动结束”。
        let quietThreshold: TimeInterval = 0.2
        // 首屏出现后的最小覆盖时长：避免在“窗口尺寸最终定型”的迟到 SIGWINCH 重绘到来
        // 之前就揭幕（开 app 的第一个标签尤其明显）。
        let minCoverageAfterContent: TimeInterval = 0.45

        guard !didRunStartupPromptRedraw else { return }
        if didReceiveProcessInput {
            // 用户已经开始输入，立即放行，别再挡着。
            finishStartupPromptDeduplication()
            return
        }
        guard terminalView.process.running else {
            finishStartupPromptDeduplication()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now >= startupHardDeadline {
            // 到硬上限，最后再尝试清一次（若仍重复），然后无论如何揭开。
            if startupRedrawCount < 3, visibleScreenLooksLikeDuplicatedStartupPrompt() {
                terminalView.process.send(data: [0x0C][...])
                invalidateDisplay()
            }
            finishStartupPromptDeduplication()
            return
        }

        // 还没有任何可见输出（PS1 尚未打印）——继续等。
        guard hasVisibleStartupContent() else {
            scheduleStartupPromptPoll(after: 0.1)
            return
        }
        if startupFirstContentUptime == 0 {
            startupFirstContentUptime = now
        }

        // 输出尚未安静（WINCH/初始化仍在抖动）——继续盖住等待，绝不此时动手。
        guard now - startupLastOutputUptime >= quietThreshold else {
            scheduleStartupPromptPoll(after: 0.1)
            return
        }

        // 已安静：启动抖动应已结束，此时判定才可靠。
        if visibleScreenLooksLikeDuplicatedStartupPrompt() {
            guard startupRedrawCount < 3 else {
                // 多次清屏仍重复，放手，避免无限纠缠。
                finishStartupPromptDeduplication()
                return
            }
            startupRedrawCount += 1
            terminalView.process.send(data: [0x0C][...])
            invalidateDisplay()
            // ^L 会产生输出并刷新安静计时；下一轮等它安静后复检。
            scheduleStartupPromptPoll(after: 0.1)
            return
        }

        // 当前安静且干净；但若还没盖够最小覆盖时长，继续盖住轮询，以防迟到的窗口
        // 定型 resize 又把提示符重绘成两条。
        if now - startupFirstContentUptime < minCoverageAfterContent {
            scheduleStartupPromptPoll(after: 0.1)
            return
        }

        // 安静、干净、且已盖够最小覆盖时长 → 揭幕。
        finishStartupPromptDeduplication()
    }

    private func finishStartupPromptDeduplication() {
        guard !didRunStartupPromptRedraw else { return }
        didRunStartupPromptRedraw = true
        startupPromptPollWorkItem?.cancel()
        hideStartupCover()
    }

    private func showStartupCover() {
        startupCoverView.layer?.removeAllAnimations()
        startupCoverView.layer?.opacity = 1
        startupCoverView.isHidden = false
    }

    private func hideStartupCover() {
        guard !startupCoverView.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startupCoverView.layer?.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        startupCoverView.layer?.add(fade, forKey: "fadeOut")
        startupCoverView.layer?.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.startupCoverView.layer?.opacity == 0 else { return }
            self.startupCoverView.isHidden = true
        }
    }

    private func hasVisibleStartupContent() -> Bool {
        visibleScreenText().contains { !$0.isWhitespace && !$0.isNewline }
    }

    private func visibleScreenLooksLikeDuplicatedStartupPrompt() -> Bool {
        let lines = visibleScreenText()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 主判据（与主题无关）：当前活动提示符是最后一条非空行，如果它在上方还有
        // 一模一样的副本，说明提示符被渲染了不止一次。对 powerline/agnoster/p10k/
        // 纯文本提示符都成立。
        if let prompt = lines.last, prompt.count >= 3 {
            let duplicates = lines.dropLast().filter { $0 == prompt }.count
            if duplicates >= 1 {
                return true
            }
        }

        // 兜底：两次重绘内容不完全一致时（例如右侧时钟在两次渲染间跳了一秒），
        // 退回到“顶部出现多条 powerline / 右对齐时间提示符”的弱判据。
        let promptLike = lines.prefix(8).filter { line in
            line.contains(" at ")
                || (line.contains("\u{e0b0}") && line.contains("\u{e0b2}"))
        }
        return promptLike.count >= 2
    }

    private func configureMetalIfNeeded() {
        guard !didConfigureMetal else { return }
        didConfigureMetal = true

        terminalView.metalBufferingMode = .perFrameAggregated
        do {
            try terminalView.setUseMetal(true)
        } catch {
            try? terminalView.setUseMetal(false)
        }
    }

    private func visibleScreenText() -> String {
        guard let terminal = terminalView.terminal else { return "" }
        return (0..<terminal.rows)
            .compactMap { row in
                terminal.getLine(row: row)?.translateToString(trimRight: true)
            }
            .joined(separator: "\n")
    }

    private func fullHistoryText() -> String {
        guard let terminal = terminalView.terminal else { return visibleScreenText() }
        return String(data: terminal.getBufferAsData(), encoding: .utf8) ?? visibleScreenText()
    }

    private static func loginShell() -> String {
        let bufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufferSize > 0 else { return "/bin/zsh" }

        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var password = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &password, buffer, bufferSize, &result) == 0 else {
            return "/bin/zsh"
        }

        return String(cString: password.pw_shell)
    }

    private static func localShellLaunchDescriptor() -> LocalShellLaunchDescriptor {
        let shellPath = loginShell()
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        var environment = environmentDictionary(shellPath: shellPath)
        var args: [String] = []
        var execName = "-" + shellName

        switch shellName {
        case "bash":
            if let rcfile = installBashIntegration(environment: &environment) {
                args = ["--rcfile", rcfile.path, "-i"]
                execName = shellName
            }
        case "fish":
            if let script = installFishIntegration(environment: &environment) {
                args = ["-C", "source \(fishSingleQuoted(script.path))"]
            }
        default:
            break
        }

        return LocalShellLaunchDescriptor(
            executable: shellPath,
            args: args,
            execName: execName,
            environment: environmentArray(from: environment),
            shellName: shellName
        )
    }

    private static func environmentArray(shellPath: String?) -> [String] {
        environmentArray(from: environmentDictionary(shellPath: shellPath))
    }

    private static func environmentDictionary(shellPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["MUSETERM_TERMINAL"] = "1"
        environment["POWERLEVEL9K_INSTANT_PROMPT"] = environment["POWERLEVEL9K_INSTANT_PROMPT"] ?? "off"
        environment["MUSETERM_ORIGINAL_XDG_CACHE_HOME"] = environment["XDG_CACHE_HOME"] ?? ""
        environment["XDG_CACHE_HOME"] = museTermShellCacheDirectory()
        if let shellPath {
            installLocalShellIntegrationIfSupported(shellPath: shellPath, environment: &environment)
        }
        return environment
    }

    private static func environmentArray(from environment: [String: String]) -> [String] {
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private static func installLocalShellIntegrationIfSupported(
        shellPath: String,
        environment: inout [String: String]
    ) {
        guard URL(fileURLWithPath: shellPath).lastPathComponent == "zsh" else { return }
        let integrationDirectory = museTermShellIntegrationDirectory(for: "zsh")
        let originalZDOTDIR = environment["ZDOTDIR"]?.isEmpty == false
            ? environment["ZDOTDIR"]!
            : FileManager.default.homeDirectoryForCurrentUser.path

        do {
            try createZshIntegrationFiles(in: integrationDirectory)
            environment["MUSETERM_REAL_ZDOTDIR"] = originalZDOTDIR
            environment["MUSETERM_SHELL_INTEGRATION"] = "zsh"
            environment["ZDOTDIR"] = integrationDirectory.path
        } catch {
            NSLog("MuseTerm shell integration disabled: \(error.localizedDescription)")
        }
    }

    private static func installBashIntegration(environment: inout [String: String]) -> URL? {
        let integrationDirectory = museTermShellIntegrationDirectory(for: "bash")
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        do {
            try FileManager.default.createDirectory(at: integrationDirectory, withIntermediateDirectories: true)
            let rcfile = integrationDirectory.appendingPathComponent("museterm.bashrc")
            try writeShellIntegrationFile(rcfile, contents: bashIntegrationScript())
            environment["MUSETERM_REAL_HOME"] = home
            environment["MUSETERM_SHELL_INTEGRATION"] = "bash"
            return rcfile
        } catch {
            NSLog("MuseTerm bash integration disabled: \(error.localizedDescription)")
            return nil
        }
    }

    private static func installFishIntegration(environment: inout [String: String]) -> URL? {
        let integrationDirectory = museTermShellIntegrationDirectory(for: "fish")

        do {
            try FileManager.default.createDirectory(at: integrationDirectory, withIntermediateDirectories: true)
            let script = integrationDirectory.appendingPathComponent("museterm.fish")
            try writeShellIntegrationFile(script, contents: fishIntegrationScript())
            environment["MUSETERM_SHELL_INTEGRATION"] = "fish"
            return script
        } catch {
            NSLog("MuseTerm fish integration disabled: \(error.localizedDescription)")
            return nil
        }
    }

    private static func museTermShellIntegrationDirectory(for shellName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("ShellIntegration", isDirectory: true)
            .appendingPathComponent(shellName, isDirectory: true)
    }

    private static func createZshIntegrationFiles(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeShellIntegrationFile(
            directory.appendingPathComponent(".zshenv"),
            contents: sourceOriginalZshFile(".zshenv")
        )
        try writeShellIntegrationFile(
            directory.appendingPathComponent(".zprofile"),
            contents: sourceOriginalZshFile(".zprofile")
        )
        try writeShellIntegrationFile(
            directory.appendingPathComponent(".zlogin"),
            contents: sourceOriginalZshFile(".zlogin")
        )
        try writeShellIntegrationFile(
            directory.appendingPathComponent(".zshrc"),
            contents: zshrcIntegrationScript()
        )
    }

    private static func sourceOriginalZshFile(_ filename: String) -> String {
        """
        # Generated by MuseTerm. Do not edit; your original \(filename) is sourced below.
        if [[ -n "${MUSETERM_REAL_ZDOTDIR:-}" && -r "${MUSETERM_REAL_ZDOTDIR}/\(filename)" ]]; then
          source "${MUSETERM_REAL_ZDOTDIR}/\(filename)"
        fi

        """
    }

    private static func zshrcIntegrationScript() -> String {
        sourceOriginalZshFile(".zshrc")
            + """
            if [[ -z "${MUSETERM_DISABLE_SHELL_INTEGRATION:-}" ]]; then
              _museterm_emit_start() {
                local muse_cmd_hex
                muse_cmd_hex=$(printf '%s' "$1" | od -An -tx1 | tr -d ' \\n')
                printf '\\033]777;MuseTerm;start=%s\\a' "$muse_cmd_hex"
              }
              _museterm_preexec() {
                _museterm_emit_start "$1"
              }
              _museterm_precmd() {
                local muse_status=$?
                printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"
              }
              typeset -ga preexec_functions
              preexec_functions=(${preexec_functions:#_museterm_preexec})
              preexec_functions=(_museterm_preexec $preexec_functions)
              typeset -ga precmd_functions
              precmd_functions=(${precmd_functions:#_museterm_precmd})
              precmd_functions=(_museterm_precmd $precmd_functions)
            fi

            """
    }

    private static func bashIntegrationScript() -> String {
        """
        # Generated by MuseTerm. Do not edit; user bash startup files are sourced below.
        if [[ -z "${MUSETERM_BASH_CONFIG_LOADED:-}" ]]; then
          export MUSETERM_BASH_CONFIG_LOADED=1
          _museterm_home="${MUSETERM_REAL_HOME:-$HOME}"
          if [[ -r "${_museterm_home}/.bash_profile" ]]; then
            source "${_museterm_home}/.bash_profile"
          elif [[ -r "${_museterm_home}/.bash_login" ]]; then
            source "${_museterm_home}/.bash_login"
          elif [[ -r "${_museterm_home}/.profile" ]]; then
            source "${_museterm_home}/.profile"
          elif [[ -r "${_museterm_home}/.bashrc" ]]; then
            source "${_museterm_home}/.bashrc"
          fi
          unset _museterm_home
        fi

        if [[ -z "${MUSETERM_DISABLE_SHELL_INTEGRATION:-}" ]]; then
          _museterm_prompt_command() {
            local muse_status=$?
            printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"
            return "$muse_status"
          }
          case ";${PROMPT_COMMAND:-};" in
            *";_museterm_prompt_command;"*) ;;
            *) PROMPT_COMMAND="_museterm_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
          esac
        fi

        """
    }

    private static func fishIntegrationScript() -> String {
        """
        # Generated by MuseTerm. Do not edit.
        if not set -q MUSETERM_DISABLE_SHELL_INTEGRATION
            functions -e _museterm_preexec 2>/dev/null
            function _museterm_preexec --on-event fish_preexec
                set -l muse_cmd_hex (printf '%s' "$argv[1]" | od -An -tx1 | tr -d ' \\n')
                printf '\\033]777;MuseTerm;start=%s\\a' $muse_cmd_hex
            end
            functions -e _museterm_postexec 2>/dev/null
            function _museterm_postexec --on-event fish_postexec
                set -l muse_status $status
                printf '\\033]777;MuseTerm;end=%d\\a' $muse_status
                return $muse_status
            end
        end

        """
    }

    private static func fishSingleQuoted(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        + "'"
    }

    private static func writeShellIntegrationFile(_ url: URL, contents: String) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func museTermShellCacheDirectory() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("ShellCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        removePowerlevelInstantPromptCache(in: url)
        return url.path
    }

    private static func removePowerlevelInstantPromptCache(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls where url.lastPathComponent.hasPrefix("p10k-instant-prompt-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum TerminalFileTransferKind: Equatable {
    case upload
    case download
}

enum TerminalFileTransferPhase: Equatable {
    case checkingRemote
    case transferring
    case completed
    case failed
}

struct TerminalFileTransferStatus: Equatable {
    let kind: TerminalFileTransferKind
    let phase: TerminalFileTransferPhase
    let reason: String?
    let progress: TerminalFileTransferProgress?

    var isActive: Bool {
        phase == .checkingRemote || phase == .transferring
    }

    var localizedSummary: String {
        if let reason, phase == .failed {
            return reason
        }

        switch (kind, phase) {
        case (.upload, .checkingRemote):
            return L10n.string("file_transfer.upload.checking")
        case (.upload, .transferring):
            return L10n.string("file_transfer.upload.running")
        case (.upload, .completed):
            return L10n.string("file_transfer.upload.completed")
        case (.upload, .failed):
            return L10n.string("file_transfer.upload.failed")
        case (.download, .checkingRemote):
            return L10n.string("file_transfer.download.checking")
        case (.download, .transferring):
            return L10n.string("file_transfer.download.running")
        case (.download, .completed):
            return L10n.string("file_transfer.download.completed")
        case (.download, .failed):
            return L10n.string("file_transfer.download.failed")
        }
    }

    static func checkingRemote(kind: TerminalFileTransferKind) -> Self {
        Self(kind: kind, phase: .checkingRemote, reason: nil, progress: nil)
    }

    static func transferring(kind: TerminalFileTransferKind, progress: TerminalFileTransferProgress?) -> Self {
        Self(kind: kind, phase: .transferring, reason: nil, progress: progress)
    }

    static func completed(kind: TerminalFileTransferKind) -> Self {
        Self(kind: kind, phase: .completed, reason: nil, progress: TerminalFileTransferProgress(percent: 1, fileName: nil, detail: nil))
    }

    static func failed(kind: TerminalFileTransferKind, reason: String) -> Self {
        Self(kind: kind, phase: .failed, reason: reason, progress: nil)
    }
}

struct TerminalFileTransferProgress: Equatable {
    let percent: Double?
    let fileName: String?
    let detail: String?

    init(percent: Double?, fileName: String?, detail: String?) {
        self.percent = percent.map { min(1, max(0, $0)) }
        self.fileName = fileName
        self.detail = detail
    }
}

private final class PendingZModemProbe {
    enum Result {
        case ready(initialRemoteBytes: [UInt8])
        case missing
    }

    let id = UUID()
    let kind: TerminalFileTransferKind
    let startLocalTransfer: ([UInt8]) -> Void
    private let readyMarker: [UInt8]
    private let missingMarker: [UInt8]
    private var buffer: [UInt8] = []
    private let maxProbeBufferSize = 16_384

    init(
        kind: TerminalFileTransferKind,
        readyMarker: String,
        missingMarker: String,
        startLocalTransfer: @escaping ([UInt8]) -> Void
    ) {
        self.kind = kind
        self.readyMarker = Array(readyMarker.utf8)
        self.missingMarker = Array(missingMarker.utf8)
        self.startLocalTransfer = startLocalTransfer
    }

    func acceptRemoteProbeData(_ bytes: [UInt8]) -> Result? {
        buffer.append(contentsOf: bytes)
        if buffer.count > maxProbeBufferSize {
            buffer.removeFirst(buffer.count - maxProbeBufferSize)
        }

        if buffer.firstRange(of: missingMarker) != nil {
            return .missing
        }

        guard let readyRange = buffer.firstRange(of: readyMarker) else {
            return nil
        }

        let trailingBytes = Array(buffer[readyRange.upperBound...])
        return .ready(initialRemoteBytes: trailingBytes)
    }
}

private extension Array where Element == UInt8 {
    func firstRange(of marker: [UInt8]) -> Range<Int>? {
        guard !marker.isEmpty, marker.count <= count else { return nil }
        for index in 0...(count - marker.count) {
            if self[index..<(index + marker.count)].elementsEqual(marker) {
                return index..<(index + marker.count)
            }
        }
        return nil
    }
}

private struct ZModemDownloadPlan {
    let remoteBasename: String
    let destinationFile: URL
    let temporaryDirectory: URL

    init(remotePath: String, destinationFile: URL) throws {
        let remoteBasename = Self.basename(from: remotePath)
        guard !remoteBasename.isEmpty else {
            throw NSError(
                domain: "MuseTermZModem",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.string("file_transfer.error.remote_basename")]
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseTermZModem", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        self.remoteBasename = remoteBasename
        self.destinationFile = destinationFile
        self.temporaryDirectory = temporaryDirectory
    }

    func moveDownloadedFileToDestination() throws {
        let expected = temporaryDirectory.appendingPathComponent(remoteBasename)
        let source: URL
        if FileManager.default.fileExists(atPath: expected.path) {
            source = expected
        } else {
            let receivedFiles = try FileManager.default.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            guard let first = receivedFiles.first else {
                throw NSError(
                    domain: "MuseTermZModem",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("file_transfer.error.download_missing")]
                )
            }
            source = first
        }

        let destinationDirectory = destinationFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.moveItem(at: source, to: destinationFile)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func basename(from remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return withoutTrailingSlash.split(separator: "/").last.map(String.init) ?? ""
    }
}

private final class ZModemProgressParser {
    private var bufferedText = ""
    private var lastFileName: String?
    private let maxBufferedTextLength = 8_192

    func accept(stderrData: Data) -> TerminalFileTransferProgress? {
        let text = String(data: stderrData, encoding: .utf8)
            ?? String(data: stderrData, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return nil }

        bufferedText.append(text)
        if bufferedText.count > maxBufferedTextLength {
            bufferedText.removeFirst(bufferedText.count - maxBufferedTextLength)
        }

        let candidates = bufferedText
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map(Self.cleanProgressLine)
            .filter { !$0.isEmpty }
        guard let line = candidates.last else { return nil }

        if let fileName = Self.fileName(from: line) {
            lastFileName = fileName
        }

        let percent = Self.percent(from: line)
        return TerminalFileTransferProgress(
            percent: percent,
            fileName: lastFileName,
            detail: line
        )
    }

    nonisolated private static func cleanProgressLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func fileName(from line: String) -> String? {
        let prefixes = ["Sending:", "Receiving:"]
        for prefix in prefixes where line.localizedCaseInsensitiveContains(prefix) {
            let parts = line.components(separatedBy: ":")
            guard parts.count > 1 else { continue }
            let candidate = parts.dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return URL(fileURLWithPath: candidate).lastPathComponent
            }
        }
        return nil
    }

    nonisolated private static func percent(from line: String) -> Double? {
        if let percentText = firstMatch(in: line, pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#),
           let percent = Double(percentText) {
            return percent / 100
        }

        if let fraction = firstFraction(in: line), fraction.total > 0 {
            return Double(fraction.current) / Double(fraction.total)
        }

        return nil
    }

    nonisolated private static func firstMatch(in line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[valueRange])
    }

    nonisolated private static func firstFraction(in line: String) -> (current: Int64, total: Int64)? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 2 else {
            return nil
        }
        guard
            let currentRange = Range(match.range(at: 1), in: line),
            let totalRange = Range(match.range(at: 2), in: line),
            let current = Int64(line[currentRange]),
            let total = Int64(line[totalRange])
        else {
            return nil
        }
        return (current, total)
    }
}

private final class ZModemBridgeProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "app.museterm.zmodem.stdin")
    private let progressParser = ZModemProgressParser()

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        onOutput: @escaping ([UInt8]) -> Void,
        onProgress: @escaping (TerminalFileTransferProgress) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            onOutput(Array(data))
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let progress = self.progressParser.accept(stderrData: data) {
                onProgress(progress)
            }
        }
        process.terminationHandler = { process in
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }

        try process.run()
    }

    func acceptRemoteData(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let data = Data(bytes)
        writeQueue.async { [stdinPipe] in
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        stdinPipe.fileHandleForWriting.closeFile()
    }
}

private enum ZModemLocalTool {
    static func executable(named name: String) -> URL? {
        searchDirectories
            .lazy
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var searchDirectories: [URL] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var seen = Set<String>()
        return (pathDirectories + commonDirectories).filter { url in
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private struct TerminalPreferenceSignature: Equatable {
    let skin: TerminalVisualSkin
    let colorPalette: TerminalColorPalette
    let fontFamily: String
    let fallbackFontFamily: String
    let fontSize: Double
    let lineHeight: Double
    let glassEnabled: Bool
    let glassMaterial: GlassMaterial
    let glassOpacity: Double
    let terminalOpacity: Double
    let tintOpacity: Double
    let optionAsMeta: Bool
    let mouseReporting: Bool
    let cursorShape: TerminalCursorShape
    let cursorBlink: Bool

    init(preferences: TerminalPreferences) {
        skin = preferences.skin
        colorPalette = preferences.colorPalette
        fontFamily = preferences.fontFamily
        fallbackFontFamily = preferences.fallbackFontFamily
        fontSize = preferences.fontSize
        lineHeight = preferences.lineHeight
        glassEnabled = preferences.glassEnabled
        glassMaterial = preferences.glassMaterial
        glassOpacity = preferences.glassOpacity
        terminalOpacity = preferences.terminalOpacity
        tintOpacity = preferences.tintOpacity
        optionAsMeta = preferences.optionAsMeta
        mouseReporting = preferences.mouseReporting
        cursorShape = preferences.cursorShape
        cursorBlink = preferences.cursorBlink
    }
}

private final class FocusableLocalProcessTerminalView: LocalProcessTerminalView {
    var onNeedsFocus: (() -> Void)?
    var onReadyForProcessStart: (() -> Void)?
    var onStableTerminalResize: ((_ cols: Int, _ rows: Int) -> Void)?
    var onProcessInputSent: (() -> Void)?
    var onTerminalTitle: ((_ title: String) -> Void)?
    var onCurrentDirectory: ((_ directory: String?) -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Bool)?
    var onReceivedProcessData: ((_ data: ArraySlice<UInt8>) -> Bool)?
    var onProcessOutputCommitted: (() -> Void)?
    private var terminalDelegateRouter: TerminalDelegateRouter?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private var selectionAutoscrollTimer: Timer?
    private var selectionAutoscrollAction: TerminalSelectionAutoscroll?
    private var lastSelectionDragEvent: NSEvent?
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048
    private let selectionAutoscrollInterval: TimeInterval = 0.08

    override init(frame: CGRect) {
        super.init(frame: frame)
        installTerminalDelegateRouter()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTerminalDelegateRouter()
    }

    deinit {
        stopSelectionAutoscroll()
    }

    private func installTerminalDelegateRouter() {
        let router = TerminalDelegateRouter(owner: self)
        terminalDelegateRouter = router
        terminalDelegate = router
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopSelectionAutoscroll()
        }
        DispatchQueue.main.async { [weak self] in
            self?.requestFocus()
            self?.onReadyForProcessStart?()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DispatchQueue.main.async { [weak self] in
            self?.onReadyForProcessStart?()
        }
    }

    func requestFocus() {
        guard let window else { return }
        window.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        requestFocus()
        onNeedsFocus?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        lastSelectionDragEvent = event
        updateSelectionAutoscroll(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        stopSelectionAutoscroll()
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        requestFocus()
        onNeedsFocus?()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let context = TerminalSelectionContext(selection: getSelection())
        let escapedItem = NSMenuItem(
            title: L10n.string("terminal.context.type_escaped_selection"),
            action: #selector(typeShellEscapedSelection(_:)),
            keyEquivalent: ""
        )
        escapedItem.target = self
        escapedItem.isEnabled = true
        menu.addItem(escapedItem)
        addSelectionContextMenuItems(to: menu, context: context)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("action.copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.string("action.paste"), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.string("action.select_all"), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func typeShellEscapedSelection(_ sender: Any) {
        guard let text = TerminalShellArgumentEscaper.typedArgument(fromTerminalSelection: getSelection()) else {
            NSSound.beep()
            return
        }
        send(source: self, data: Array(text.utf8)[...])
    }

    private func addSelectionContextMenuItems(to menu: NSMenu, context: TerminalSelectionContext?) {
        guard let context else { return }

        var addedContextSection = false
        func addContextSeparatorIfNeeded() {
            guard !addedContextSection else { return }
            menu.addItem(.separator())
            addedContextSection = true
        }

        addContextSeparatorIfNeeded()
        if let escaped = context.escapedPathArgument {
            menu.addItem(makeCopyItem("terminal.context.copy_escaped_selection", text: escaped))
        }
        menu.addItem(makeCopyItem("terminal.context.copy_redacted_selection", text: RunbookSensitiveRedactor.redact(context.trimmedText)))
        menu.addItem(makeCopyItem("terminal.context.copy_markdown_selection", text: context.markdownCodeBlock))
        menu.addItem(makeCopyItem("terminal.context.copy_ai_prompt", text: context.aiPrompt))

        if let url = context.normalizedURL {
            addContextSeparatorIfNeeded()
            menu.addItem(makeOpenURLItem("terminal.context.open_url", url: url))
            menu.addItem(makeCopyItem("terminal.context.copy_curl_command", text: "curl -i \(TerminalShellArgumentEscaper.shellArgument(url.absoluteString))"))
            menu.addItem(makeTypeCommandItem("terminal.context.type_curl_command", command: "curl -i \(TerminalShellArgumentEscaper.shellArgument(url.absoluteString))"))
        }

        if context.isLikelyPath, let escaped = context.escapedPathArgument {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu(
                "terminal.context.path_submenu",
                items: pathMenuItems(context: context, escapedPath: escaped)
            ))
        }

        if let port = context.port {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu(
                "terminal.context.port_submenu",
                items: [
                    makeOpenURLItem("terminal.context.open_localhost_port", url: URL(string: "http://127.0.0.1:\(port)")!),
                    makeTypeCommandItem("terminal.context.type_port_lsof", command: "lsof -nP -iTCP:\(port) -sTCP:LISTEN"),
                    makeCopyItem("terminal.context.copy_localhost_url", text: "http://127.0.0.1:\(port)")
                ]
            ))
        }

        if let pid = context.pid {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu(
                "terminal.context.pid_submenu",
                items: [
                    makeTypeCommandItem("terminal.context.type_pid_ps", command: "ps -p \(pid) -o pid,ppid,stat,etime,pcpu,pmem,command"),
                    makeTypeCommandItem("terminal.context.type_pid_lsof", command: "lsof -p \(pid)"),
                    makeTypeCommandItem("terminal.context.type_pid_kill", command: "kill \(pid)"),
                    makeTypeCommandItem("terminal.context.type_pid_kill9", command: "kill -9 \(pid)")
                ]
            ))
        }

        if let hash = context.gitHash {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu(
                "terminal.context.git_submenu",
                items: [
                    makeTypeCommandItem("terminal.context.type_git_show_stat", command: "git show --stat \(hash)"),
                    makeTypeCommandItem("terminal.context.type_git_show", command: "git show \(hash)")
                ]
            ))
        }

        if let prettyJSON = context.prettyJSON {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu(
                "terminal.context.json_submenu",
                items: [
                    makeCopyItem("terminal.context.copy_pretty_json", text: prettyJSON),
                    makeTypeCommandItem("terminal.context.type_jq_command", command: "jq .")
                ]
            ))
        }

        if let searchArgument = context.searchCommandArgument {
            addContextSeparatorIfNeeded()
            menu.addItem(makeTypeCommandItem("terminal.context.type_rg_command", command: "rg \(searchArgument)"))
        }

        let transformItems = transformMenuItems(for: context)
        if !transformItems.isEmpty {
            addContextSeparatorIfNeeded()
            menu.addItem(makeSubmenu("terminal.context.transform_submenu", items: transformItems))
        }
    }

    private func pathMenuItems(context: TerminalSelectionContext, escapedPath: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            makeCopyItem("terminal.context.copy_escaped_path", text: escapedPath),
            makeTypeCommandItem("terminal.context.type_ls_path", command: "ls -la \(escapedPath)"),
            makeTypeCommandItem("terminal.context.type_stat_path", command: "stat \(escapedPath)"),
            makeTypeCommandItem("terminal.context.type_file_path", command: "file \(escapedPath)")
        ]
        if let removeCommand = context.interactiveRemoveCommand {
            items.append(makeTypeCommandItem("terminal.context.type_rm_path", command: removeCommand))
        }
        if let localPath = context.localPathCandidate,
           FileManager.default.fileExists(atPath: localPath) {
            items.insert(
                makeRevealFileItem("terminal.context.reveal_in_finder", path: localPath),
                at: 1
            )
        }
        if context.isExistingLocalDirectory {
            items.insert(
                makeTypeCommandItem("terminal.context.type_cd_path", command: "cd \(escapedPath)"),
                at: 1
            )
        }
        return items
    }

    private func transformMenuItems(for context: TerminalSelectionContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let encoded = context.urlEncodedText, encoded != context.trimmedText {
            items.append(makeCopyItem("terminal.context.copy_url_encoded", text: encoded))
        }
        if let decoded = context.urlDecodedText {
            items.append(makeCopyItem("terminal.context.copy_url_decoded", text: decoded))
        }
        items.append(makeCopyItem("terminal.context.copy_base64_encoded", text: context.base64EncodedText))
        if let decoded = context.base64DecodedText {
            items.append(makeCopyItem("terminal.context.copy_base64_decoded", text: decoded))
        }
        return items
    }

    private func makeSubmenu(_ titleKey: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(titleKey), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.string(titleKey))
        items.forEach { submenu.addItem($0) }
        item.submenu = submenu
        return item
    }

    private func makeCopyItem(_ titleKey: String, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(titleKey), action: #selector(copyRepresentedText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = text
        return item
    }

    private func makeTypeCommandItem(_ titleKey: String, command: String) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(titleKey), action: #selector(typeRepresentedCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    private func makeOpenURLItem(_ titleKey: String, url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(titleKey), action: #selector(openRepresentedURL(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        return item
    }

    private func makeRevealFileItem(_ titleKey: String, path: String) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(titleKey), action: #selector(revealRepresentedFile(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = path
        return item
    }

    @objc private func copyRepresentedText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func typeRepresentedCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        send(source: self, data: Array(command.utf8)[...])
    }

    @objc private func openRepresentedURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealRepresentedFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    override func otherMouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        requestFocus()
        onNeedsFocus?()
        super.otherMouseDown(with: event)
    }

    private func updateSelectionAutoscroll(for event: NSEvent) {
        guard selectionActive else {
            stopSelectionAutoscroll()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let action = TerminalSelectionAutoscroll.action(pointerY: point.y, viewHeight: bounds.height) else {
            stopSelectionAutoscroll()
            return
        }

        selectionAutoscrollAction = action
        guard selectionAutoscrollTimer == nil else { return }

        let timer = Timer(timeInterval: selectionAutoscrollInterval, repeats: true) { [weak self] _ in
            self?.handleSelectionAutoscrollTick()
        }
        selectionAutoscrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleSelectionAutoscrollTick() {
        guard selectionActive, let action = selectionAutoscrollAction else {
            stopSelectionAutoscroll()
            return
        }

        switch action.direction {
        case .up:
            scrollUp(lines: action.lines)
        case .down:
            scrollDown(lines: action.lines)
        }

        if let event = lastSelectionDragEvent {
            super.mouseDragged(with: event)
        }
    }

    private func stopSelectionAutoscroll() {
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
        selectionAutoscrollAction = nil
        lastSelectionDragEvent = nil
    }

    override func paste(_ sender: Any) {
        onNeedsFocus?()
        super.paste(sender)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let echoEnabled = cachedTerminalEchoEnabled()
        guard onSendToProcess?(bytes, echoEnabled) ?? true else { return }
        onProcessInputSent?()
        if shouldRecordInput?() == true {
            if echoEnabled {
                rememberExpectedEcho(bytes)
            }
        }
        super.send(source: source, data: data)
    }

    fileprivate func terminalDidResize(newCols: Int, newRows: Int) {
        pendingResizeWorkItem?.cancel()
        guard process.running else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.process.running else { return }
            guard self.terminal.cols == newCols, self.terminal.rows == newRows else {
                self.terminalDidResize(newCols: self.terminal.cols, newRows: self.terminal.rows)
                return
            }
            self.onStableTerminalResize?(newCols, newRows)
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    fileprivate func terminalDidSetTitle(_ title: String) {
        onTerminalTitle?(title)
    }

    fileprivate func terminalDidUpdateCurrentDirectory(_ directory: String?) {
        onCurrentDirectory?(directory)
    }

    fileprivate func terminalDidSend(data: ArraySlice<UInt8>) {
        send(source: self, data: data)
    }

    fileprivate func terminalDidCopyToClipboard(_ content: Data) {
        guard let string = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([string as NSString])
    }

    fileprivate func terminalClipboardData() -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    fileprivate func terminalDidRequestOpenLink(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate func terminalDidBell() {
        NSSound.beep()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if onReceivedProcessData?(slice) == true {
            return
        }
        if shouldRecordInput?() == true, !isExpectedEcho(slice) {
            invalidateTerminalEchoCache()
        }
        super.dataReceived(slice: slice)
        onProcessOutputCommitted?()
    }

    var terminalEchoEnabled: Bool {
        guard process.running else { return false }
        var attributes = termios()
        guard tcgetattr(process.childfd, &attributes) == 0 else { return false }
        return (attributes.c_lflag & tcflag_t(ECHO)) != 0
    }

    private func invalidateTerminalEchoCache() {
        cachedEchoEnabled = nil
        cachedEchoCheckedAt = 0
        pendingEchoBytes.removeAll(keepingCapacity: true)
    }

    private func cachedTerminalEchoEnabled() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedEchoEnabled, now - cachedEchoCheckedAt <= maxEchoCacheAge {
            return cachedEchoEnabled
        }
        let fresh = terminalEchoEnabled
        cachedEchoEnabled = fresh
        cachedEchoCheckedAt = now
        return fresh
    }

    private func rememberExpectedEcho(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pendingEchoBytes.append(contentsOf: bytes)
        if pendingEchoBytes.count > maxPendingEchoBytes {
            pendingEchoBytes.removeFirst(pendingEchoBytes.count - maxPendingEchoBytes)
        }
    }

    private func isExpectedEcho(_ slice: ArraySlice<UInt8>) -> Bool {
        guard !slice.isEmpty, !pendingEchoBytes.isEmpty else { return false }
        let bytes = Array(slice)
        guard pendingEchoBytes.starts(with: bytes) else { return false }
        pendingEchoBytes.removeFirst(bytes.count)
        return true
    }
}

private final class TerminalDelegateRouter: TerminalViewDelegate {
    private weak var owner: FocusableLocalProcessTerminalView?

    init(owner: FocusableLocalProcessTerminalView) {
        self.owner = owner
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        owner?.terminalDidResize(newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        owner?.terminalDidSetTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        owner?.terminalDidUpdateCurrentDirectory(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        owner?.terminalDidSend(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        owner?.terminalDidRequestOpenLink(link)
    }

    func bell(source: TerminalView) {
        owner?.terminalDidBell()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        owner?.terminalDidCopyToClipboard(content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        owner?.terminalClipboardData()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
