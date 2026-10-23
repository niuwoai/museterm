import AppKit
import Darwin
import MetalKit
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
        let didBecomeActive = session.controller.setActive(isActive)
        DispatchQueue.main.async {
            session.controller.ensureProcessStarted()
            if isActive {
                session.controller.focusTerminal()
                // 只在切到前台时整屏重绘；打字时 session 频繁发布变更也会走到这里，
                // 每次都全量重绘会白白吃 CPU。
                if didBecomeActive {
                    session.controller.invalidateDisplay()
                }
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
    // 预热：把容器临时挂到一个离屏窗口里，让 shell 进程在后台就绪（跑完 rc、打完首个提示符），
    // 等真正开标签时容器被 SwiftUI 领养到真窗口。prewarmWindow 仅为满足 canStartProcess 的
    // window!=nil + 尺寸前提，不上屏。
    private var prewarmWindow: NSWindow?
    private var wasPrewarmed = false
    private var didAttachToLiveWindow = false
    private var startupPromptPollWorkItem: DispatchWorkItem?
    private var startupHardDeadline: TimeInterval = 0
    private var startupLastOutputUptime: TimeInterval = 0
    private var startupFirstContentUptime: TimeInterval = 0
    private var startupRedrawCount = 0
    private var didRunStartupPromptRedraw = false
    private var didReceiveProcessInput = false
    private var didConfigureMetal = false
    private weak var lastActiveWindow: NSWindow?
    private var lastAppliedPreferences: TerminalPreferenceSignature?
    private var pendingZModemProbe: PendingZModemProbe?
    private var activeZModemTransfer: ZModemBridgeProcess?
    private let automaticZModemUploadDetector = AutomaticZModemUploadDetector()
    private var isAwaitingAutomaticUploadSelection = false
    private var automaticUploadRemoteBytes: [UInt8] = []
    /// Identifies the transfer whose `onExit` is still welcome. A superseded
    /// or torn-down bridge exits later on a background queue; the stale
    /// callback must not clobber the status of a newer transfer.
    private var activeZModemTransferToken: UUID?
    private var activeSessionTunnel: SessionTunnelBridge?
    private var activeSessionTunnelID: UUID?
    private let shellIntegrationParser = TerminalShellIntegrationParser()
    private var pendingShellIntegrationEvents: [TerminalShellIntegrationEvent] = []
    private weak var preferences: TerminalPreferences?
    private var pendingSafetyInputBytes: [UInt8] = []
    private let maxPendingSafetyInputBytes = 8_192
    private var sshDiagnosticBuffer = ""
    private var pendingSSHDiagnosticMessage: String?
    private var emittedSSHDiagnosticKinds: Set<String> = []
    private var latestSSHConnectionIssueKind: SSHConnectionIssueKind?
    private var sshReconnectAttemptCount = 0
    private var sshLastStartUptime: TimeInterval = 0
    private var pendingSSHReconnectWorkItem: DispatchWorkItem?
    private var isTerminating = false
    // 输出快照节流：fullHistoryText() 会全量扫终端历史 buffer（复杂度 ≈ 历史行数 × 列宽），
    // 若每段输出都扫一遍，长历史下主线程会被打满。普通输出合并到至多每 250ms 一次，
    // 只有命令边界（shell integration 事件）才立即取快照以保证命令输出切分准确。
    private var pendingOutputSnapshotWorkItem: DispatchWorkItem?
    private var lastOutputSnapshotUptime: TimeInterval = 0
    private let outputSnapshotThrottleInterval: TimeInterval = 0.25
    // 节流快照的缓存副本：给 tool bridge 等只读消费方复用，避免它们再各自全量扫 buffer。
    // contentRevision 随每次快照刷新递增，供外部做“内容没变就跳过”的脏检查。
    private var cachedHistoryText: String?
    private(set) var contentRevision = 0
    private var agentForegroundPID: pid_t?
    private var agentForegroundRunID = UUID()
    private var lastAgentSampleUptime: TimeInterval = -.infinity

    func sampleAgentForeground(now: Date = Date()) {
        guard case .localShell = session?.launchConfiguration else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastAgentSampleUptime >= 1 else { return }
        lastAgentSampleUptime = uptime
        guard didStart, terminalView.process.running else { return }
        let pid = tcgetpgrp(terminalView.process.childfd)
        if agentForegroundPID != pid {
            agentForegroundPID = pid
            agentForegroundRunID = UUID()
        }
        var name = [CChar](repeating: 0, count: 1_024)
        let length = pid > 0 ? proc_name(pid, &name, UInt32(name.count)) : 0
        let executable = length > 0 ? String(cString: name) : ""
        let kind = TerminalAgentScreenRules.kind(executable: executable)
        let runID = kind.flatMap { session?.observedAgentCommandID(kind: $0) } ?? agentForegroundRunID
        session?.observeAgentForeground(kind: kind, processRunID: runID,
            screen: kind == nil ? "" : liveAgentScreenText(), now: now)
    }

    private func liveAgentScreenText() -> String {
        guard let terminal = terminalView.terminal else { return "" }
        return TerminalAgentScreenReader.liveTail(terminal)
    }

    init(session: TerminalSession) {
        self.session = session
        super.init()
        configureViews()
    }

    func apply(preferences: TerminalPreferences) {
        self.preferences = preferences
        layoutTerminalViews()
        applyScrollbackLines(preferences.scrollbackLines)
        applyGraphicsPolicy(cacheMegabytes: preferences.imageCacheMegabytes)
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
        terminalView.selectedTextBackgroundColor = preferences.skin.terminalSelectionBackground(
            opacity: CGFloat(preferences.terminalOpacity)
        )
        terminalView.caretColor = preferences.skin.caret
        terminalView.font = preferences.terminalFont
        terminalView.installColors(preferences.skin.ansiSwiftTermColors)
        terminalView.lineSpacing = CGFloat(preferences.lineHeight)
        terminalView.optionAsMetaKey = preferences.optionAsMeta
        terminalView.allowMouseReporting = preferences.mouseReporting
        applyCursorStyle(shape: preferences.cursorShape, blink: preferences.cursorBlink)
        terminalView.customBlockGlyphs = true
        terminalView.antiAliasCustomBlockGlyphs = true
        terminalView.useBrightColors = true

        configureRenderer(terminalOpacity: preferences.terminalOpacity)
        configureTransparentTerminalSurface()

        requestTerminalRepaint()
    }

    /// 清空终端承载层的兜底底色，让 Core Graphics 的背景 alpha 能继续透到窗口后方。
    /// 同时兼容已经创建过的 MTKView，避免渲染器切换过程中残留不透明图层。
    private func configureTransparentTerminalSurface() {
        terminalView.layer?.isOpaque = false
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        for metalView in terminalView.subviews.compactMap({ $0 as? MTKView }) {
            metalView.layer?.isOpaque = false
            metalView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func applyScrollbackLines(_ lines: Int) {
        guard let terminal = terminalView.terminal else { return }
        let normalized = TerminalPreferences.clampedScrollbackLines(lines)
        guard terminal.options.scrollback != normalized else { return }
        terminal.changeScrollback(normalized)
    }

    private func applyGraphicsPolicy(cacheMegabytes: Int) {
        guard let terminal = terminalView.terminal else { return }
        TerminalGraphicsPolicy.apply(to: terminal, cacheMegabytes: cacheMegabytes)
    }

    func layoutTerminalViews() {
        let bounds = container.bounds
        setFrameIfNeeded(visualEffectView, bounds)
        setFrameIfNeeded(tintView, bounds)
        let horizontalInset = max(4, ceil(terminalView.font.pointSize * 0.36))
        let marginWidth = min(horizontalInset, bounds.width / 2)
        setFrameIfNeeded(terminalLeadingMarginView, CGRect(
            x: 0,
            y: 0,
            width: marginWidth,
            height: bounds.height
        ))
        setFrameIfNeeded(terminalTrailingMarginView, CGRect(
            x: max(0, bounds.width - marginWidth),
            y: 0,
            width: marginWidth,
            height: bounds.height
        ))
        // 必须一次性算好终端 frame 再赋值：SwiftTerm 的 setFrameSize 每次都会 resize 终端并向
        // PTY 发 SIGWINCH。若先设成全宽再缩回，打字触发的每次 updateNSView 都会让列数来回跳，
        // 表现为画面抖动、CPU 升高，zsh 右提示符（RPROMPT）按错误列宽折行。
        setFrameIfNeeded(terminalView, CGRect(
            x: bounds.minX + marginWidth,
            y: bounds.minY,
            width: max(0, bounds.width - marginWidth * 2),
            height: bounds.height
        ))
        setFrameIfNeeded(startupCoverView, bounds)
        handleAttachToLiveWindowIfNeeded()
        schedulePendingProcessStartIfReady()
    }

    private func setFrameIfNeeded(_ view: NSView, _ frame: CGRect) {
        guard view.frame != frame else { return }
        view.frame = frame
    }

    // 预热会话首次落到真窗口时，容器尺寸从离屏默认值跳到实际大小，会触发一次 SIGWINCH 重绘，
    // p10k 等可能把提示符重画成多条。此时 shell 已就绪，复用启动遮罩盖住这次重排：因首屏内容
    // 早已存在，遮罩会在输出安静后很快（约 0.5s）揭幕，而不是从零等 shell 冷启动的那 ~1.5s。
    private func handleAttachToLiveWindowIfNeeded() {
        guard wasPrewarmed, !didAttachToLiveWindow else { return }
        guard let window = terminalView.window, window !== prewarmWindow else { return }
        didAttachToLiveWindow = true
        beginStartupPromptDeduplication()
    }

    func terminate() {
        session?.releaseAIControl(reason: "terminal_closed")
        isTerminating = true
        activeSessionTunnel?.forceCancel(error: nil)
        activeSessionTunnel = nil
        activeSessionTunnelID = nil
        session?.updateSessionTunnelStatus(nil)
        pendingSSHReconnectWorkItem?.cancel()
        pendingSSHReconnectWorkItem = nil
        pendingOutputSnapshotWorkItem?.cancel()
        pendingOutputSnapshotWorkItem = nil
        if prewarmWindow != nil {
            container.removeFromSuperview()
            prewarmWindow?.orderOut(nil)
            prewarmWindow = nil
        }
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

    /// 后台预热：把容器塞进一个离屏窗口，令 shell 进程立即启动并跑完 rc，
    /// 之后开标签直接复用这个已就绪的会话。重复调用与已启动的会话都安全跳过。
    func prewarm(preferences: TerminalPreferences?) {
        guard !didStart, prewarmWindow == nil else { return }
        wasPrewarmed = true
        let size = NSSize(width: 900, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        container.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(container)
        prewarmWindow = window
        if let preferences {
            apply(preferences: preferences)
        }
        layoutTerminalViews()
        ensureProcessStarted()
    }

    /// 标签被真正取用时调用：把容器从离屏窗口摘下，交还给 SwiftUI 领养到真窗口。
    func adoptFromPrewarm() {
        guard prewarmWindow != nil else { return }
        container.removeFromSuperview()
        prewarmWindow?.orderOut(nil)
        prewarmWindow = nil
    }

    func reconnectSSH() {
        guard case .ssh = session?.launchConfiguration,
              !terminalView.process.running else {
            return
        }
        pendingSSHReconnectWorkItem?.cancel()
        pendingSSHReconnectWorkItem = nil
        sshReconnectAttemptCount = 0
        session?.state = .running
        terminalView.feed(text: "\n\(L10n.string("ssh.reconnect.manual_start"))\n")
        didStart = false
        pendingStart = true
        resetSSHDiagnosticsForNewAttempt()
        schedulePendingProcessStartIfReady()
    }

    func focusTerminal() {
        terminalView.requestFocus()
    }

    /// 返回本次调用是否让终端变为可见（从隐藏切回，或刚挂到新窗口）。
    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
        let window = container.window
        let movedToNewWindow = window !== lastActiveWindow
        let didBecomeActive = isActive && (container.isHidden || movedToNewWindow)
        if isActive { lastActiveWindow = window }
        container.alphaValue = 1
        container.isHidden = !isActive
        terminalView.isHidden = !isActive
        terminalView.layer?.isHidden = !isActive
        return didBecomeActive
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

    @MainActor
    func toolSnapshot(
        index: Int,
        isSelected: Bool,
        maxHistoryCharacters: Int
    ) -> TerminalToolTabSnapshot {
        let recentCommandBlocks = Array(session?.commandBlocks.suffix(50) ?? [])
        return TerminalToolTabSnapshot(
            agent: session?.agentStatus,
            aiControlled: session?.aiLease != nil,
            aiLeaseExpiresAt: session?.aiLease?.expiresAt,
            aiRequiresTakeover: session?.aiRequiresTakeover,
            id: session?.id.uuidString ?? UUID().uuidString,
            index: index,
            title: session?.tabTitle ?? "",
            subtitle: session?.tabSubtitle,
            currentDirectory: session?.currentDirectory,
            shellName: session?.shellName,
            sessionTunnelStatus: session?.sessionTunnelStatus.map(TerminalToolSessionTunnelSnapshot.init(status:)),
            isSelected: isSelected,
            state: session?.toolStateText ?? "unknown",
            columns: terminalView.terminal?.cols ?? 0,
            rows: terminalView.terminal?.rows ?? 0,
            screen: visibleScreenText(),
            history: String(latestHistoryText().suffix(maxHistoryCharacters)),
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

    private var isSendingToolInput = false
    private var toolInputOwner: String?

    func sendToolInput(bytes: [UInt8], owner: String? = nil) throws {
        try session?.authorizeAIInput(owner: owner)
        guard didStart, terminalView.process.running else {
            throw TerminalToolError.processUnavailable
        }
        guard activeSessionTunnel == nil else {
            throw TerminalToolError.sessionTunnelActive
        }
        try session?.archiveAIInput(bytes, echoEnabled: terminalView.terminalEchoEnabled)
        isSendingToolInput = true
        toolInputOwner = owner
        defer {
            isSendingToolInput = false
            toolInputOwner = nil
        }
        sendProcessInput(bytes: bytes)
        guard terminalView.didSendLastInput else { throw TerminalAIControlError.inputRejected }
    }

    func sendProcessInput(bytes: [UInt8]) {
        terminalView.send(source: terminalView, data: bytes[...])
    }

    var isProcessRunning: Bool {
        didStart && terminalView.process.running
    }

    func startZModemUpload(fileURLs: [URL]) {
        guard session?.aiLease == nil else { return }
        guard activeSessionTunnel == nil else {
            reportFileTransferFailure(
                kind: .upload,
                reason: L10n.string("session_tunnel.error.file_transfer_during_tunnel")
            )
            return
        }
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
        guard session?.aiLease == nil else { return }
        guard activeSessionTunnel == nil else {
            reportFileTransferFailure(
                kind: .download,
                reason: L10n.string("session_tunnel.error.file_transfer_during_tunnel")
            )
            return
        }
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

    func startSessionTunnel(configuration: SessionTunnelConfiguration) throws {
        guard didStart, terminalView.process.running else {
            throw SessionTunnelStartError.processUnavailable
        }
        guard activeSessionTunnel == nil else {
            throw SessionTunnelStartError.tunnelAlreadyActive
        }
        guard pendingZModemProbe == nil, activeZModemTransfer == nil else {
            throw SessionTunnelStartError.fileTransferActive
        }

        let bridgeID = UUID()
        let usesUITestFixture = ProcessInfo.processInfo.arguments.contains(
            "-ui-testing-session-tunnel-fixture"
        )
        let bridgeToken = usesUITestFixture
            ? "musetermuitestsessiontunnel"
            : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let bridge = SessionTunnelBridge(
            configuration: configuration,
            token: bridgeToken,
            shouldSendBootstrapCommand: !usesUITestFixture,
            sendToRemote: { [weak self] bytes in
                guard !usesUITestFixture else { return }
                DispatchQueue.main.async {
                    guard let self,
                          self.activeSessionTunnelID == bridgeID,
                          self.terminalView.process.running else {
                        return
                    }
                    self.terminalView.process.send(data: bytes[...])
                }
            },
            onStatus: { [weak self] status in
                guard let self, self.activeSessionTunnelID == bridgeID else { return }
                self.session?.updateSessionTunnelStatus(status)
            },
            onFinished: { [weak self] error in
                guard let self, self.activeSessionTunnelID == bridgeID else { return }
                self.activeSessionTunnel = nil
                self.activeSessionTunnelID = nil
                if let error {
                    var failed = self.session?.sessionTunnelStatus
                        ?? .starting(configuration: configuration)
                    failed.phase = .failed
                    failed.errorMessage = error
                    self.session?.updateSessionTunnelStatus(failed)
                } else {
                    self.session?.updateSessionTunnelStatus(nil)
                    if !usesUITestFixture, self.terminalView.process.running {
                        self.terminalView.process.send(data: [0x0D][...])
                    }
                }
            }
        )
        activeSessionTunnelID = bridgeID
        activeSessionTunnel = bridge
        session?.updateSessionTunnelStatus(.starting(configuration: configuration))
        bridge.start()
        if usesUITestFixture,
           let ready = SessionTunnelFrameCodec.encode(
            SessionTunnelProtocolMessage(token: bridgeToken, type: "ready")
           ) {
            bridge.acceptRemoteData(ready)
        }
    }

    func stopSessionTunnel() {
        activeSessionTunnel?.stop()
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
        guard !terminalView.process.running else {
            session?.state = .running
            return
        }
        session?.releaseAIControl(reason: "process_exited")
        session?.finishActiveCommand(
            exitCode: exitCode,
            completionSource: .processExit,
            historySnapshot: refreshHistoryTextCache()
        )
        if let activeSessionTunnel {
            activeSessionTunnel.forceCancel(
                error: L10n.string("session_tunnel.error.process_terminated")
            )
        }
        // PTY 死亡时本地 lrzsz 桥接进程必须一并回收，否则它会一直挂着，
        // 侧栏状态也永远停在"传输中"。
        if pendingZModemProbe != nil || isAwaitingAutomaticUploadSelection || activeZModemTransfer != nil {
            let kind = pendingZModemProbe?.kind
                ?? (activeZModemTransfer != nil ? session?.fileTransferStatus?.kind : nil)
            cancelActiveZModemTransfer()
            if let kind {
                reportFileTransferFailure(
                    kind: kind,
                    reason: L10n.string("file_transfer.error.process_unavailable")
                )
            }
        }
        if scheduleSSHReconnectIfNeeded(exitCode: exitCode) {
            return
        }
        session?.state = .exited(exitCode)
        session?.reportProcessExitAttention(exitCode: exitCode)
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
        terminalView.onTerminalBell = { [weak self] in
            self?.session?.reportBellAttention()
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
        terminalView.shouldCopyOnSelect = { [weak self] in
            self?.preferences?.copyOnSelect ?? false
        }
        terminalView.linkContext = { [weak self] in
            TerminalLinkContext(
                currentDirectory: self?.session?.currentDirectory,
                isRemoteSession: self?.session?.executionContext.targetKind == .ssh
            )
        }
        terminalView.shouldOpenWebImagesInViewer = { [weak self] in
            self?.preferences?.openWebImagesInViewer ?? true
        }
        terminalView.onSendToProcess = { [weak self] data, echoEnabled in
            guard let self else { return true }
            let fromTool = self.isSendingToolInput
            let owner = self.toolInputOwner
            // Consume before entering any modal safety confirmation, which can run
            // a nested event loop and receive unrelated human input.
            self.isSendingToolInput = false
            self.toolInputOwner = nil
            self.session?.expireAIControlIfNeeded()
            guard fromTool || self.session?.aiLease == nil else { return false }
            guard self.activeSessionTunnel == nil else { return false }
            guard self.approveProcessInputIfNeeded(data: data, echoEnabled: echoEnabled) else {
                return false
            }
            if fromTool {
                do { try self.session?.authorizeAIInput(owner: owner) }
                catch { return false }
            }
            if self.activeZModemTransfer != nil {
                // ZMODEM 传输期间键盘输入不得混入协议流；Ctrl+C 双端中止，
                // 其余按键一律吞掉。
                if data.contains(0x03) {
                    self.requestUserCancelZModemTransfer()
                }
                return false
            }
            if self.pendingZModemProbe != nil {
                // 探测阶段远端仍是 shell：按键放行（不记录）；Ctrl+C 在
                // 打断远端命令的同时结束本地的探测等待。
                if data.contains(0x03), let probe = self.pendingZModemProbe {
                    self.pendingZModemProbe = nil
                    self.session?.updateFileTransferStatus(
                        .failed(kind: probe.kind, reason: L10n.string("file_transfer.error.cancelled"))
                    )
                }
                return true
            }
            self.session?.recordInputIfNeeded(data: data, echoEnabled: echoEnabled)
            // historySnapshot 是 @autoclosure：仅在回车/Ctrl-C 需要切分命令时才全量扫历史。
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
            if self.handleProcessOutputForSessionTunnel(data) {
                return true
            }
            self.observeSSHProcessOutput(data)
            if self.handleProcessOutputForZModem(data) {
                return true
            }
            self.handleProcessOutputForShellIntegration(data)
            return false
        }
        terminalView.onProcessOutputCommitted = { [weak self] in
            guard let self else { return }
            if self.pendingShellIntegrationEvents.isEmpty {
                self.scheduleThrottledProcessOutputSnapshot()
            } else {
                self.commitProcessOutputSnapshot()
            }
            self.flushPendingSSHDiagnosticMessage()
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

    private func observeSSHProcessOutput(_ data: ArraySlice<UInt8>) {
        guard case .ssh(let profile) = session?.launchConfiguration,
              let output = String(bytes: data, encoding: .utf8),
              !output.isEmpty else {
            return
        }

        sshDiagnosticBuffer.append(output)
        if sshDiagnosticBuffer.count > 8_000 {
            sshDiagnosticBuffer = String(sshDiagnosticBuffer.suffix(8_000))
        }

        guard let issue = SSHConnectionIssueClassifier.classify(sshDiagnosticBuffer),
              emittedSSHDiagnosticKinds.insert(issue.rawValue).inserted else {
            return
        }

        latestSSHConnectionIssueKind = issue
        let routeContext = SSHRouteDiagnosticAnalyzer.context(
            for: profile,
            diagnosticText: sshDiagnosticBuffer
        )
        let suggestion = [
            routeContext?.message,
            issue.suggestion,
            SSHRouteProbeGuideBuilder.guide(for: profile, issue: issue)?.message,
            SSHConnectionIssueRepairGuide.message(
                for: issue,
                profile: profile,
                diagnosticText: sshDiagnosticBuffer
            )
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
        pendingSSHDiagnosticMessage = L10n.format(
            "ssh.diagnostic.message",
            issue.title,
            issue.summary,
            suggestion
        )
    }

    private func flushPendingSSHDiagnosticMessage() {
        guard let message = pendingSSHDiagnosticMessage else { return }
        pendingSSHDiagnosticMessage = nil
        terminalView.feed(text: "\n\(message)\n")
    }

    private func handleProcessOutputForZModem(_ data: ArraySlice<UInt8>) -> Bool {
        noteStartupOutputActivity()
        if let activeZModemTransfer {
            activeZModemTransfer.acceptRemoteData(Array(data))
            return true
        }

        if isAwaitingAutomaticUploadSelection {
            automaticUploadRemoteBytes.append(contentsOf: data)
            return true
        }

        guard let pendingZModemProbe else {
            guard activeSessionTunnel == nil,
                  let initialRemoteBytes = automaticZModemUploadDetector.accept(Array(data)) else {
                return false
            }
            beginAutomaticZModemUpload(initialRemoteBytes: initialRemoteBytes)
            return true
        }
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

    private func beginAutomaticZModemUpload(initialRemoteBytes: [UInt8]) {
        isAwaitingAutomaticUploadSelection = true
        automaticUploadRemoteBytes = initialRemoteBytes
        session?.updateFileTransferStatus(.checkingRemote(kind: .upload))

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAwaitingAutomaticUploadSelection else { return }
            guard let toolURL = ZModemLocalTool.executable(named: "sz") else {
                self.finishAutomaticUploadSelection(
                    failureReason: L10n.format("file_transfer.error.local_tool_missing", "sz")
                )
                return
            }

            let panel = NSOpenPanel()
            panel.title = L10n.string("file_transfer.upload.panel_title")
            panel.prompt = L10n.string("file_transfer.upload")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true

            guard panel.runModal() == .OK, !panel.urls.isEmpty else {
                self.finishAutomaticUploadSelection(
                    failureReason: L10n.string("file_transfer.error.cancelled")
                )
                return
            }

            let remoteBytes = self.automaticUploadRemoteBytes
            self.isAwaitingAutomaticUploadSelection = false
            self.automaticUploadRemoteBytes.removeAll(keepingCapacity: true)
            self.automaticZModemUploadDetector.reset()
            self.startLocalZModemTransfer(
                kind: .upload,
                executableURL: toolURL,
                arguments: ["-b"] + panel.urls.map(\.path),
                currentDirectory: nil,
                initialRemoteBytes: remoteBytes
            )
        }
    }

    private func finishAutomaticUploadSelection(failureReason: String) {
        isAwaitingAutomaticUploadSelection = false
        automaticUploadRemoteBytes.removeAll(keepingCapacity: true)
        automaticZModemUploadDetector.reset()
        sendProcessInput(bytes: ZModemBridgeProcess.remoteCancelSequence)
        reportFileTransferFailure(kind: .upload, reason: failureReason)
        terminalView.feed(text: "\n\(failureReason)\n")
    }

    private func handleProcessOutputForSessionTunnel(_ data: ArraySlice<UInt8>) -> Bool {
        guard let activeSessionTunnel else { return false }
        noteStartupOutputActivity()
        activeSessionTunnel.acceptRemoteData(Array(data))
        return true
    }

    private func handleProcessOutputForShellIntegration(_ data: ArraySlice<UInt8>) {
        guard activeZModemTransfer == nil,
              pendingZModemProbe == nil,
              !isAwaitingAutomaticUploadSelection,
              activeSessionTunnel == nil else {
            return
        }
        pendingShellIntegrationEvents.append(contentsOf: shellIntegrationParser.accept(data))
    }

    private func commitProcessOutputSnapshot() {
        pendingOutputSnapshotWorkItem?.cancel()
        pendingOutputSnapshotWorkItem = nil
        lastOutputSnapshotUptime = ProcessInfo.processInfo.systemUptime
        let historySnapshot = refreshHistoryTextCache()
        flushPendingShellIntegrationEvents(historySnapshot: historySnapshot)
        session?.observeProcessOutput(historySnapshot: historySnapshot)
        session?.recordOutputRevision(contentRevision)
        sampleAgentForeground()
    }

    func latestHistoryText() -> String {
        if let cachedHistoryText { return cachedHistoryText }
        return refreshHistoryTextCache()
    }

    @discardableResult
    private func refreshHistoryTextCache() -> String {
        let text = fullHistoryText()
        cachedHistoryText = text
        contentRevision += 1
        return text
    }

    private func scheduleThrottledProcessOutputSnapshot() {
        // 已有排队的快照任务时直接合并，保证输出停止后仍有一次“尾随”快照收口。
        guard pendingOutputSnapshotWorkItem == nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastOutputSnapshotUptime
        let delay = max(0, outputSnapshotThrottleInterval - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.commitProcessOutputSnapshot()
        }
        pendingOutputSnapshotWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
            case .executionContext(let context):
                session?.updateExecutionContext(context)
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
        SafetyInputAnalyzer.pendingCommandCandidate(
            existingBytes: pendingSafetyInputBytes,
            appending: data
        )
    }

    private func updatePendingSafetyInput(data: [UInt8], echoEnabled: Bool) {
        pendingSafetyInputBytes = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: pendingSafetyInputBytes,
            appending: data,
            echoEnabled: echoEnabled,
            maxBytes: maxPendingSafetyInputBytes
        )
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
            let token = UUID()
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
                        guard let self, self.activeZModemTransferToken == token else { return }
                        self.session?.updateFileTransferStatus(.transferring(kind: kind, progress: progress))
                    }
                },
                onExit: { [weak self] exitCode, endReason in
                    DispatchQueue.main.async {
                        guard let self, self.activeZModemTransferToken == token else { return }
                        self.finishZModemTransfer(
                            kind: kind,
                            exitCode: exitCode,
                            endReason: endReason,
                            downloadPlan: downloadPlan
                        )
                    }
                }
            )
            activeZModemTransfer = transfer
            activeZModemTransferToken = token
            session?.updateFileTransferStatus(.transferring(kind: kind, progress: nil))
            if !initialRemoteBytes.isEmpty {
                transfer.acceptRemoteData(initialRemoteBytes)
            }
        } catch {
            reportFileTransferFailure(kind: kind, reason: error.localizedDescription)
        }
    }

    private func finishZModemTransfer(
        kind: TerminalFileTransferKind,
        exitCode: Int32,
        endReason: ZModemBridgeEndReason,
        downloadPlan: ZModemDownloadPlan?
    ) {
        activeZModemTransfer = nil
        activeZModemTransferToken = nil
        defer { downloadPlan?.cleanup() }

        switch endReason {
        case .userCancelled:
            let reason = L10n.string("file_transfer.error.cancelled")
            reportFileTransferFailure(kind: kind, reason: reason)
            terminalView.feed(text: "\n\(reason)\n")
        case .timedOut:
            let reason = L10n.format("file_transfer.error.stalled", Int(activeTransferIdleTimeout))
            reportFileTransferFailure(kind: kind, reason: reason)
            terminalView.feed(text: "\n\(reason)\n")
        case .none:
            if exitCode == 0 {
                do {
                    try downloadPlan?.moveDownloadedFileToDestination()
                    session?.updateFileTransferStatus(.completed(kind: kind))
                    terminalView.feed(text: "\n\(L10n.string(kind == .upload ? "file_transfer.upload.completed" : "file_transfer.download.completed"))\n")
                } catch {
                    reportFileTransferFailure(kind: kind, reason: error.localizedDescription)
                }
            } else {
                reportFileTransferFailure(kind: kind, reason: L10n.format("file_transfer.error.local_exit", exitCode))
            }
        }
    }

    /// Idle window before an in-flight transfer is declared dead. Mirrors
    /// ZModemBridgeProcess's default; kept here for the timeout message.
    private var activeTransferIdleTimeout: TimeInterval { 30 }

    /// Silently tear down any probe/transfer so a new one can take the PTY
    /// (or the PTY itself died). The stale bridge's late `onExit` is dropped
    /// by the token guard.
    private func cancelActiveZModemTransfer() {
        pendingZModemProbe = nil
        isAwaitingAutomaticUploadSelection = false
        automaticUploadRemoteBytes.removeAll(keepingCapacity: true)
        automaticZModemUploadDetector.reset()
        activeZModemTransferToken = nil
        activeZModemTransfer?.cancel(reason: .userCancelled)
        activeZModemTransfer = nil
    }

    /// User-facing cancel (Ctrl+C or the sidebar button): abort both sides
    /// and let the normal `onExit` path report "cancelled".
    func requestUserCancelZModemTransfer() {
        if isAwaitingAutomaticUploadSelection {
            finishAutomaticUploadSelection(failureReason: L10n.string("file_transfer.error.cancelled"))
            return
        }
        if let probe = pendingZModemProbe {
            pendingZModemProbe = nil
            session?.updateFileTransferStatus(
                .failed(kind: probe.kind, reason: L10n.string("file_transfer.error.cancelled"))
            )
        }
        activeZModemTransfer?.cancel(reason: .userCancelled)
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
        session?.markStartupCommandsStarted()
        applyScrollbackLines(preferences?.scrollbackLines ?? TerminalPreferences.defaultScrollbackLines)
        applyGraphicsPolicy(
            cacheMegabytes: preferences?.imageCacheMegabytes
                ?? TerminalPreferences.defaultImageCacheMegabytes
        )

        switch session?.launchConfiguration ?? .localShell() {
        case .localShell(let startDirectory, let profile):
            let descriptor = Self.localShellLaunchDescriptor(profile: profile)
            let currentDirectory = TerminalWorkingDirectory.normalizedExistingDirectory(startDirectory)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            session?.updateShellName(descriptor.shellName)
            // 先盖上遮罩，再启动进程：保证 shell 的第一条 PS1 输出抵达前画面已被遮住。
            beginStartupPromptDeduplication()
            session?.beginProcessRun()
            terminalView.startProcess(
                executable: descriptor.executable,
                args: descriptor.args,
                environment: descriptor.environment,
                execName: descriptor.execName,
                currentDirectory: currentDirectory
            )
            if let profile, !profile.normalized.startupCommands.isEmpty {
                drainStartupCommands(profile.normalized.startupCommands)
            } else {
                session?.markStartupCommandsFinished()
            }
        case .ssh(let profile):
            do {
                resetSSHDiagnosticsForNewAttempt()
                sshLastStartUptime = ProcessInfo.processInfo.systemUptime
                let descriptor = try SSHConfigMaterializer.descriptor(for: profile)
                session?.beginProcessRun()
                terminalView.startProcess(
                    executable: descriptor.executable,
                    args: descriptor.args,
                    environment: Self.environmentArray(shellPath: nil),
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                session?.state = .running
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

    private func resetSSHDiagnosticsForNewAttempt() {
        sshDiagnosticBuffer = ""
        pendingSSHDiagnosticMessage = nil
        emittedSSHDiagnosticKinds.removeAll(keepingCapacity: true)
        latestSSHConnectionIssueKind = nil
    }

    private func scheduleSSHReconnectIfNeeded(exitCode: Int32?) -> Bool {
        guard !isTerminating,
              case .ssh(let profile) = session?.launchConfiguration else {
            return false
        }
        if sshLastStartUptime > 0,
           ProcessInfo.processInfo.systemUptime - sshLastStartUptime > 60 {
            sshReconnectAttemptCount = 0
        }

        let disconnectReason = SSHDisconnectReasonClassifier.classify(
            issue: latestSSHConnectionIssueKind,
            exitCode: exitCode,
            diagnosticText: sshDiagnosticBuffer
        )
        switch SSHReconnectPolicy.decision(
            profile: profile,
            issue: latestSSHConnectionIssueKind,
            exitCode: exitCode,
            completedAttempts: sshReconnectAttemptCount,
            disconnectReason: disconnectReason
        ) {
        case .suppress:
            if shouldExplainSuppressedSSHReconnect(profile: profile, exitCode: exitCode, reason: disconnectReason) {
                terminalView.feed(text: "\n\(L10n.format("ssh.reconnect.stopped_with_reason", disconnectReason.title))\n")
            }
            return false
        case .exhausted:
            terminalView.feed(text: "\n\(L10n.format("ssh.reconnect.exhausted_with_reason", disconnectReason.title))\n")
            return false
        case .reconnect(let delaySeconds):
            sshReconnectAttemptCount += 1
            let attempt = sshReconnectAttemptCount
            let maxAttempts = profile.normalized.automaticReconnectAttempts
            terminalView.feed(
                text: "\n\(L10n.format("ssh.reconnect.scheduled_with_reason", disconnectReason.title, attempt, maxAttempts, delaySeconds))\n"
            )
            session?.state = .running
            pendingSSHReconnectWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.isTerminating,
                      case .ssh = self.session?.launchConfiguration,
                      !self.terminalView.process.running else {
                    return
                }
                self.terminalView.feed(text: "\(L10n.format("ssh.reconnect.attempting", attempt))\n")
                self.didStart = false
                self.pendingStart = false
                self.resetSSHDiagnosticsForNewAttempt()
                self.startProcessIfNeeded()
            }
            pendingSSHReconnectWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
            return true
        }
    }

    private func shouldExplainSuppressedSSHReconnect(
        profile: SSHConnectionProfile,
        exitCode: Int32?,
        reason: SSHDisconnectReasonKind
    ) -> Bool {
        let clean = profile.normalized
        guard clean.automaticReconnectEnabled, clean.automaticReconnectAttempts > 0 else { return false }
        guard exitCode != 0 else { return false }
        return !reason.allowsAutomaticReconnect
    }

    private func drainStartupCommands(_ commands: [String]) {
        guard !commands.isEmpty else {
            session?.markStartupCommandsFinished()
            return
        }
        Task { [weak self] in
            for command in commands {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    guard let self, self.terminalView.process.running else { return }
                    self.terminalView.send(source: self.terminalView, data: Array((command + "\n").utf8)[...])
                }
            }
            await MainActor.run {
                self?.session?.markStartupCommandsFinished()
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
        applyScrollbackLines(preferences?.scrollbackLines ?? TerminalPreferences.defaultScrollbackLines)
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

    /// SwiftTerm 当前的 Metal 承载面会被窗口服务器按不透明 drawable 合成。
    /// 半透明终端改用 Core Graphics，确保背景 alpha 真正透到窗口后方；恢复到
    /// 100% 不透明时自动重新启用 Metal，不让常规不透明场景承担性能损失。
    private func configureRenderer(terminalOpacity: Double) {
        guard terminalOpacity < 0.999 else {
            configureMetalIfNeeded()
            return
        }
        guard terminalView.isUsingMetalRenderer else {
            didConfigureMetal = false
            return
        }
        try? terminalView.setUseMetal(false)
        didConfigureMetal = false
    }

    func visibleScreenText() -> String {
        guard let terminal = terminalView.terminal else { return "" }
        return (0..<terminal.rows)
            .compactMap { row in
                terminal.getLine(row: row)?.translateToString(trimRight: true)
            }
            .joined(separator: "\n")
    }

    var terminalColumns: Int {
        terminalView.terminal?.cols ?? 0
    }

    var terminalRows: Int {
        terminalView.terminal?.rows ?? 0
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

    private static func localShellLaunchDescriptor(profile: TerminalProfile? = nil) -> LocalShellLaunchDescriptor {
        let clean = profile?.normalized
        let shellPath = resolveShellExecutable(kind: clean?.shell ?? .login, customPath: clean?.customShellPath ?? "")
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        var environment = environmentDictionary(shellPath: shellPath)
        // App 进程继承的 SHELL 是系统登录 shell；profile 选了别的 shell（如 fish）时必须改成
        // 实际启动的那个，否则集成脚本按 $SHELL 上报，标签会误显示成 zsh。
        environment["SHELL"] = shellPath
        applyProfileEnvironment(clean, into: &environment)
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

    /// 按 profile 指定的 shell 类型解析可执行文件路径；找不到时回落系统登录 shell。
    private static func resolveShellExecutable(kind: ProfileShellKind, customPath: String) -> String {
        switch kind {
        case .login:
            return loginShell()
        case .zsh:
            return firstExecutable(["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"])
                ?? "/bin/zsh"
        case .bash:
            return firstExecutable(["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash", "/usr/bin/bash"])
                ?? "/bin/bash"
        case .fish:
            return firstExecutable(["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])
                ?? loginShell()
        case .custom:
            let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return firstExecutable([trimmed]) ?? loginShell()
        }
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 把 profile 的自定义环境变量与 prompt 相关变量注入环境字典。
    /// prompt 差异全走环境变量，集成脚本保持共享静态文件。
    private static func applyProfileEnvironment(_ profile: TerminalProfile?, into environment: inout [String: String]) {
        guard let profile else { return }
        for (key, value) in profile.environment {
            environment[key] = value
        }
        // .system 不设置 style 变量，集成脚本的 prompt 分派整体跳过，用户 PS1 保持不变。
        if profile.promptStyle != .system {
            environment["MUSETERM_PROFILE_PROMPT_STYLE"] = profile.promptStyle.rawValue
            if profile.promptStyle == .custom, !profile.customPrompt.isEmpty {
                environment["MUSETERM_PROFILE_CUSTOM_PROMPT"] = profile.customPrompt
            }
        }
    }

    private static func environmentArray(shellPath: String?) -> [String] {
        environmentArray(from: environmentDictionary(shellPath: shellPath))
    }

    private static func environmentDictionary(shellPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["MUSETERM_TERMINAL"] = "1"
        for (key, value) in TerminalGraphicsPolicy.environmentVariables(appVersion: AppVersion.value) {
            environment[key] = value
        }
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
            + posixContextIntegrationFunctions
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
                _museterm_emit_context
              }
              typeset -ga preexec_functions
              preexec_functions=(${preexec_functions:#_museterm_preexec})
              preexec_functions=(_museterm_preexec $preexec_functions)
              typeset -ga precmd_functions
              precmd_functions=(${precmd_functions:#_museterm_precmd})
              precmd_functions=(_museterm_precmd $precmd_functions)
            fi
            _museterm_emit_context

            """
            + zshProfilePromptScript()
    }

    /// 按 profile 的 prompt 风格设置 PROMPT；仅当 MUSETERM_PROFILE_PROMPT_STYLE 非空时生效，
    /// 因此系统默认（.system）不会改动用户 PS1。
    private static func zshProfilePromptScript() -> String {
        """
        if [[ -z "${MUSETERM_DISABLE_SHELL_INTEGRATION:-}" && -n "${MUSETERM_PROFILE_PROMPT_STYLE:-}" ]]; then
          setopt prompt_subst 2>/dev/null
          _museterm_git_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null }
          case "$MUSETERM_PROFILE_PROMPT_STYLE" in
            minimal) PROMPT='%1~ ❯ ' ;;
            path) PROMPT='%n@%m %~ %# ' ;;
            git) PROMPT='%~ $(_museterm_git_branch)%# ' ;;
            twoLine) PROMPT=$'%~\\n%# ' ;;
            custom) [[ -n "${MUSETERM_PROFILE_CUSTOM_PROMPT:-}" ]] && PROMPT="$MUSETERM_PROFILE_CUSTOM_PROMPT" ;;
          esac
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

        """
            + posixContextIntegrationFunctions
            + """

        if [[ -z "${MUSETERM_DISABLE_SHELL_INTEGRATION:-}" ]]; then
          _museterm_prompt_command() {
            local muse_status=$?
            printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"
            _museterm_emit_context
            return "$muse_status"
          }
          case ";${PROMPT_COMMAND:-};" in
            *";_museterm_prompt_command;"*) ;;
            *) PROMPT_COMMAND="_museterm_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
          esac
        fi
        _museterm_emit_context

        """
            + bashProfilePromptScript()
    }

    private static func bashProfilePromptScript() -> String {
        """
        if [[ -z "${MUSETERM_DISABLE_SHELL_INTEGRATION:-}" && -n "${MUSETERM_PROFILE_PROMPT_STYLE:-}" ]]; then
          _museterm_git_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }
          case "$MUSETERM_PROFILE_PROMPT_STYLE" in
            minimal) PS1='\\W ❯ ' ;;
            path) PS1='\\u@\\h \\w \\$ ' ;;
            git) PS1='\\w $(_museterm_git_branch)\\$ ' ;;
            twoLine) PS1='\\w\\n\\$ ' ;;
            custom) [[ -n "${MUSETERM_PROFILE_CUSTOM_PROMPT:-}" ]] && PS1="$MUSETERM_PROFILE_CUSTOM_PROMPT" ;;
          esac
        fi

        """
    }

    private static func fishIntegrationScript() -> String {
        """
        # Generated by MuseTerm. Do not edit.
        if not set -q MUSETERM_DISABLE_SHELL_INTEGRATION
            function _museterm_hex
                printf '%s' "$argv[1]" | od -An -tx1 | tr -d ' \\n'
            end
            function _museterm_emit_context
                set -l muse_cwd_hex (_museterm_hex "$PWD")
                set -l muse_user_hex (_museterm_hex (id -un 2>/dev/null))
                set -l muse_uid (id -u 2>/dev/null)
                set -l muse_host_hex (_museterm_hex (hostname 2>/dev/null))
                set -l muse_shell_hex (_museterm_hex "$SHELL")
                printf '\\033]777;MuseTerm;context=%s,%s,%s,%s,%s\\a' "$muse_cwd_hex" "$muse_user_hex" "$muse_uid" "$muse_host_hex" "$muse_shell_hex"
            end
            functions -e _museterm_preexec 2>/dev/null
            function _museterm_preexec --on-event fish_preexec
                set -l muse_cmd_hex (printf '%s' "$argv[1]" | od -An -tx1 | tr -d ' \\n')
                printf '\\033]777;MuseTerm;start=%s\\a' $muse_cmd_hex
            end
            functions -e _museterm_postexec 2>/dev/null
            function _museterm_postexec --on-event fish_postexec
                set -l muse_status $status
                printf '\\033]777;MuseTerm;end=%d\\a' $muse_status
                _museterm_emit_context
                return $muse_status
            end
            _museterm_emit_context
        end

        """
            + fishProfilePromptScript()
    }

    private static let posixContextIntegrationFunctions = """
        _museterm_hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \\n'; }
        _museterm_emit_context() {
          local muse_cwd_hex muse_user_hex muse_uid muse_host_hex muse_shell_hex
          muse_cwd_hex=$(_museterm_hex "${PWD:-}")
          muse_user_hex=$(_museterm_hex "$(id -un 2>/dev/null)")
          muse_uid=$(id -u 2>/dev/null)
          muse_host_hex=$(_museterm_hex "$(hostname 2>/dev/null)")
          muse_shell_hex=$(_museterm_hex "${SHELL:-}")
          printf '\\033]777;MuseTerm;context=%s,%s,%s,%s,%s\\a' "$muse_cwd_hex" "$muse_user_hex" "$muse_uid" "$muse_host_hex" "$muse_shell_hex"
        }

        """

    private static func fishProfilePromptScript() -> String {
        """
        if not set -q MUSETERM_DISABLE_SHELL_INTEGRATION; and set -q MUSETERM_PROFILE_PROMPT_STYLE
            switch $MUSETERM_PROFILE_PROMPT_STYLE
                case minimal
                    function fish_prompt; printf '%s ❯ ' (prompt_pwd); end
                case path
                    function fish_prompt; printf '%s@%s %s > ' (whoami) (hostname -s) (pwd); end
                case git
                    function fish_prompt
                        set -l muse_branch (git rev-parse --abbrev-ref HEAD 2>/dev/null)
                        printf '%s %s> ' (pwd) "$muse_branch "
                    end
                case twoLine
                    function fish_prompt; printf '%s\\n> ' (pwd); end
                case custom
                    if set -q MUSETERM_PROFILE_CUSTOM_PROMPT; eval $MUSETERM_PROFILE_CUSTOM_PROMPT; end
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

// TerminalFileTransfer* 状态模型与 ZMODEM 桥接类型
// （PendingZModemProbe / ZModemDownloadPlan / ZModemProgressParser /
// ZModemBridgeProcess / ZModemLocalTool）已迁至 TerminalZModemSupport.swift。

private struct TerminalPreferenceSignature: Equatable {
    let skin: TerminalVisualSkin
    let fontFamily: String
    let fallbackFontFamilies: [String]
    let fontSize: Double
    let lineHeight: Double
    let glassEnabled: Bool
    let glassMaterial: GlassMaterial
    let glassOpacity: Double
    let windowOpacity: Double
    let terminalOpacity: Double
    let tintOpacity: Double
    let optionAsMeta: Bool
    let mouseReporting: Bool
    let scrollbackLines: Int
    let imageCacheMegabytes: Int
    let cursorShape: TerminalCursorShape
    let cursorBlink: Bool

    init(preferences: TerminalPreferences) {
        skin = preferences.skin
        fontFamily = preferences.fontFamily
        fallbackFontFamilies = preferences.fallbackFontFamilies
        fontSize = preferences.fontSize
        lineHeight = preferences.lineHeight
        glassEnabled = preferences.glassEnabled
        glassMaterial = preferences.glassMaterial
        glassOpacity = preferences.glassOpacity
        windowOpacity = preferences.windowOpacity
        terminalOpacity = preferences.terminalOpacity
        tintOpacity = preferences.tintOpacity
        optionAsMeta = preferences.optionAsMeta
        mouseReporting = preferences.mouseReporting
        scrollbackLines = preferences.scrollbackLines
        imageCacheMegabytes = preferences.imageCacheMegabytes
        cursorShape = preferences.cursorShape
        cursorBlink = preferences.cursorBlink
    }
}

enum TerminalIMECommitPolicy {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    static func shouldForwardReturnAfterCommit(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        hadMarkedText: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        hadMarkedText
            && !hasMarkedText
            && returnKeyCodes.contains(keyCode)
            && modifiers.intersection(disallowedModifiers).isEmpty
    }
}

private final class FocusableLocalProcessTerminalView: LocalProcessTerminalView {
    var onNeedsFocus: (() -> Void)?
    var onReadyForProcessStart: (() -> Void)?
    var onStableTerminalResize: ((_ cols: Int, _ rows: Int) -> Void)?
    var onProcessInputSent: (() -> Void)?
    var onTerminalBell: (() -> Void)?
    var onTerminalTitle: ((_ title: String) -> Void)?
    var onCurrentDirectory: ((_ directory: String?) -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var shouldCopyOnSelect: (() -> Bool)?
    var linkContext: (() -> TerminalLinkContext)?
    var shouldOpenWebImagesInViewer: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Bool)?
    var onReceivedProcessData: ((_ data: ArraySlice<UInt8>) -> Bool)?
    var onProcessOutputCommitted: (() -> Void)?
    private var terminalDelegateRouter: TerminalDelegateRouter?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var imeReturnMonitor: Any?
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private var selectionAutoscrollTimer: Timer?
    private var selectionAutoscrollAction: TerminalSelectionAutoscroll?
    private var lastSelectionDragEvent: NSEvent?
    private var isTrackingMouseSelection = false
    private var selectionChangedDuringMouseGesture = false
    private var lastMouseUpLocation: NSPoint?
    private var didRequestOpenLinkDuringMouseUp = false
    private var linkNoticeView: NSView?
    private var linkNoticeWorkItem: DispatchWorkItem?
    private let linkNoticeDuration: TimeInterval = 2.4
    private let linkNoticeFadeDuration: TimeInterval = 0.25
    private let linkNoticeOffset: CGFloat = 14
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048
    private let selectionAutoscrollInterval: TimeInterval = 0.08

    // #1 高频输出防卡：把 PTY 数据合批喂入终端解析器，按 runloop tick 限量 flush。
    // 效果：原先“每来一片数据就同步 feed + 触发一次重绘”，多 tab 刷屏时把主线程压垮、
    // 且积压无上限（杀掉源头后仍要逐行啃完 → 永久 100%、界面冻死）。
    // 改为缓冲后合并喂入：多片合并成一次 feed → 一次重绘；每 tick 最多解析 maxFeedBytesPerFlush，
    // 剩余留到下一 tick 并把 runloop 让给 UI 事件，主线程始终可响应、杀源后能快速排空恢复。
    // 全程在主线程（dataReceived 由 LocalProcess 在 main queue 上回调），故无需加锁。
    private var pendingFeedBytes: [UInt8] = []
    private var feedFlushScheduled = false
    private let maxFeedBytesPerFlush = 256 * 1024

    override init(frame: CGRect) {
        super.init(frame: frame)
        installTerminalDelegateRouter()
        installIMEReturnMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTerminalDelegateRouter()
        installIMEReturnMonitor()
    }

    deinit {
        if let imeReturnMonitor {
            NSEvent.removeMonitor(imeReturnMonitor)
        }
        stopSelectionAutoscroll()
    }

    private func installIMEReturnMonitor() {
        imeReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.window?.firstResponder === self,
                  TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                      keyCode: event.keyCode,
                      modifiers: event.modifierFlags,
                      hadMarkedText: self.hasMarkedText(),
                      hasMarkedText: false
                  ) else { return event }

            // The monitor runs before SwiftTerm's NSTextInputClient handles the
            // key. Check on the next main-loop turn whether Return really ended
            // composition, then forward the consumed Return to the PTY.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasMarkedText() else { return }
                self.send(txt: "\r")
            }
            return event
        }
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
        isTrackingMouseSelection = true
        selectionChangedDuringMouseGesture = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        lastSelectionDragEvent = event
        updateSelectionAutoscroll(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        stopSelectionAutoscroll()
        lastMouseUpLocation = convert(event.locationInWindow, from: nil)
        didRequestOpenLinkDuringMouseUp = false
        super.mouseUp(with: event)
        if shouldTryBareFileNameLink(for: event) {
            openBareFileNameLink(at: event)
        }
        finishMouseSelectionGesture()
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if isTrackingMouseSelection {
            selectionChangedDuringMouseGesture = true
        }
    }

    private func finishMouseSelectionGesture() {
        defer {
            isTrackingMouseSelection = false
            selectionChangedDuringMouseGesture = false
        }
        guard let text = TerminalCopyOnSelectPolicy.textToCopy(
            isEnabled: shouldCopyOnSelect?() ?? false,
            selectionChangedDuringGesture: selectionChangedDuringMouseGesture,
            selection: getSelection()
        ) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private(set) var didSendLastInput = false

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        didSendLastInput = false
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
        didSendLastInput = true
    }

    // Emulator replies (cursor position, device attributes, etc.) are protocol traffic,
    // not human input. Keep full-screen programs responsive while input is locked.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        super.send(source: self, data: data)
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
        didRequestOpenLinkDuringMouseUp = true
        let context = linkContext?() ?? TerminalLinkContext(currentDirectory: nil, isRemoteSession: false)
        switch TerminalLinkResolver.resolve(link, context: context) {
        case .success(.webPage(let url)), .success(.otherScheme(let url)):
            NSWorkspace.shared.open(url)
        case .success(.webImage(let url)):
            openWebImage(url)
        case .success(.localItem(let url)):
            NSWorkspace.shared.open(url)
        case .success(.revealInFinder(let url)):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showLinkNotice(L10n.string("terminal.link.revealed_in_finder"))
        case .failure(.remotePath):
            NSSound.beep()
            showLinkNotice(L10n.string("terminal.link.remote_path"))
        case .failure(.notFound(let path)):
            NSSound.beep()
            showLinkNotice(L10n.format("terminal.link.not_found", path))
        case .failure(.invalid):
            NSSound.beep()
            showLinkNotice(L10n.string("terminal.link.invalid"))
        }
    }

    /// 只处理"⌘+单击、SwiftTerm 没识别出链接、也没拖出选区"的情况
    private func shouldTryBareFileNameLink(for event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.clickCount == 1
            && !didRequestOpenLinkDuringMouseUp
            && !selectionChangedDuringMouseGesture
    }

    /// 裸文件名兜底：只有本机确实存在该文件时才打开；找不到就安静地什么都不做，
    /// 免得 ⌘+点到普通单词时也弹"找不到文件"
    private func openBareFileNameLink(at event: NSEvent) {
        guard let (column, row) = screenCell(for: event),
              let cells = screenRowCharacters(row: row),
              let word = TerminalLinkWordExtractor.candidate(in: cells, at: column) else { return }
        let context = linkContext?() ?? TerminalLinkContext(currentDirectory: nil, isRemoteSession: false)
        guard case .success(let target) = TerminalLinkResolver.resolve(word, context: context) else { return }
        switch target {
        case .localItem(let url):
            NSWorkspace.shared.open(url)
        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showLinkNotice(L10n.string("terminal.link.revealed_in_finder"))
        case .webPage, .webImage, .otherScheme:
            // 带 scheme 的链接 SwiftTerm 已经识别过；走到这里说明不是完整链接，不处理
            break
        }
    }

    /// 点击位置对应的可见区域（列, 行）。SwiftTerm 的格子尺寸不公开：行高由
    /// getOptimalFrameSize 反推，列宽按 SwiftTerm 同样的"W 字宽 + 像素对齐"规则计算
    private func screenCell(for event: NSEvent) -> (column: Int, row: Int)? {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        let cellHeight = getOptimalFrameSize().height / CGFloat(terminal.rows)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let glyph = font.glyph(withName: "W")
        let cellWidth = ceil(font.advancement(forGlyph: glyph).width * scale) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / cellWidth)
        let row = Int((frame.height - point.y) / cellHeight)
        guard (0..<terminal.cols).contains(column), (0..<terminal.rows).contains(row) else { return nil }
        return (column, row)
    }

    /// 一格一个字符，下标与列号对齐；空格子和宽字符的占位格是 NUL，按分隔符处理
    private func screenRowCharacters(row: Int) -> [Character]? {
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: row) else { return nil }
        let count = min(terminal.cols, line.count)
        return (0..<count).map { terminal.getCharacter(for: line[$0]) }
    }

    private func openWebImage(_ url: URL) {
        guard shouldOpenWebImagesInViewer?() ?? true else {
            NSWorkspace.shared.open(url)
            return
        }
        showLinkNotice(L10n.string("terminal.link.downloading_image"))
        TerminalLinkImageDownloader.download(url) { [weak self] result in
            switch result {
            case .success(let fileURL):
                self?.hideLinkNotice()
                NSWorkspace.shared.open(fileURL)
            case .failure(let error):
                // 只记 host + path，query 里可能带 token
                NSLog("QTerm image link download failed host=%@ path=%@ error=%@", url.host ?? "", url.path, String(describing: error))
                NSWorkspace.shared.open(url)
                self?.showLinkNotice(L10n.string("terminal.link.image_fallback_browser"))
            }
        }
    }

    /// 在点击位置附近浮一个小提示，几秒后淡出；不往终端里写字，避免污染输出
    private func showLinkNotice(_ text: String) {
        hideLinkNotice()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 6
        container.addSubview(label)

        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 5
        let maxWidth = max(bounds.width - linkNoticeOffset * 2, 120)
        let labelSize = label.fittingSize
        let width = min(labelSize.width + horizontalPadding * 2, maxWidth)
        let height = labelSize.height + verticalPadding * 2
        label.frame = NSRect(x: horizontalPadding, y: verticalPadding, width: width - horizontalPadding * 2, height: labelSize.height)

        let anchor = lastMouseUpLocation ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let y = isFlipped ? anchor.y + linkNoticeOffset : anchor.y - linkNoticeOffset - height
        let x = min(max(anchor.x - width / 2, linkNoticeOffset), max(bounds.width - width - linkNoticeOffset, linkNoticeOffset))
        container.frame = NSRect(
            x: x,
            y: min(max(y, 0), max(bounds.height - height, 0)),
            width: width,
            height: height
        )
        addSubview(container)
        linkNoticeView = container

        let workItem = DispatchWorkItem { [weak self] in self?.hideLinkNotice(animated: true) }
        linkNoticeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + linkNoticeDuration, execute: workItem)
    }

    private func hideLinkNotice(animated: Bool = false) {
        linkNoticeWorkItem?.cancel()
        linkNoticeWorkItem = nil
        guard let view = linkNoticeView else { return }
        linkNoticeView = nil
        guard animated else {
            view.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = linkNoticeFadeDuration
            view.animator().alphaValue = 0
        }, completionHandler: {
            view.removeFromSuperview()
        })
    }

    fileprivate func terminalDidBell() {
        NSSound.beep()
        onTerminalBell?()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if onReceivedProcessData?(slice) == true {
            return
        }
        if shouldRecordInput?() == true, !isExpectedEcho(slice) {
            invalidateTerminalEchoCache()
        }
        // 到达时的 echo 检测 / onReceivedProcessData 已同步跑完（顺序敏感，保持原样）；
        // 真正的 feed（解析+重绘）改为缓冲后合并限量 flush，见 flushPendingFeed()。
        pendingFeedBytes.append(contentsOf: slice)
        scheduleFeedFlush()
    }

    private func scheduleFeedFlush() {
        guard !feedFlushScheduled else { return }
        feedFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingFeed()
        }
    }

    private func flushPendingFeed() {
        feedFlushScheduled = false
        guard !pendingFeedBytes.isEmpty else { return }
        let end = min(pendingFeedBytes.count, maxFeedBytesPerFlush)
        // super.dataReceived == feed(byteArray:)，纯流式解析，合批喂入与逐片喂入等价。
        super.dataReceived(slice: pendingFeedBytes[0..<end])
        pendingFeedBytes.removeFirst(end)
        onProcessOutputCommitted?()
        // 仍有积压 → 下一 tick 继续（让出 runloop 给 UI 事件，保持界面可响应）。
        if !pendingFeedBytes.isEmpty {
            scheduleFeedFlush()
        }
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
