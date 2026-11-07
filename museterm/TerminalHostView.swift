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
    @Environment(\.terminalKeyboardOverlayActive) private var keyboardOverlayActive
    let isActive: Bool
    var focusesInput = true

    /// 自动聚焦条件：窗格可见、持有输入焦点，且没有键盘浮层。浮层（命令面板、
    /// AI 指令输入条）开着时，终端必须让出第一响应者，否则用户敲进浮层的字符
    /// 会被 shell 收走。
    private var shouldAutoFocus: Bool {
        TerminalInputFocusPolicy.shouldAutoFocus(
            isActive: isActive,
            focusesInput: focusesInput,
            keyboardOverlayActive: keyboardOverlayActive
        )
    }

    func makeNSView(context: Context) -> NSView {
        let controller = session.controller
        controller.setKeyboardOverlayActive(keyboardOverlayActive)
        controller.setActive(isActive)
        DispatchQueue.main.async {
            controller.ensureProcessStarted()
            if shouldAutoFocus {
                controller.focusTerminalAutomatically()
            }
        }
        return controller.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.controller.setKeyboardOverlayActive(keyboardOverlayActive)
        session.controller.layoutTerminalViews()
        session.controller.apply(preferences: preferences)
        let didBecomeActive = session.controller.setActive(isActive)
        DispatchQueue.main.async {
            session.controller.ensureProcessStarted()
            if shouldAutoFocus {
                // 控制器在执行时还会再检查一次浮层状态：SwiftUI 的延迟聚焦和命令面板
                // 的延迟聚焦是两条独立的异步任务，先排队的终端聚焦可能后执行。
                session.controller.focusTerminalAutomatically()
            }
            // 只在切到前台时整屏重绘；打字时 session 频繁发布变更也会走到这里，
            // 每次都全量重绘会白白吃 CPU。浮层开着时也要照常重绘，不只是聚焦时。
            if didBecomeActive {
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
    private let terminalView: FocusableLocalProcessTerminalView
    private(set) var runtimeHandle: TerminalRuntimeSessionHandle?
    private(set) var runtimeInputErrorCode: String?
    private var runtimeForegroundPID: pid_t?
    private var runtimeExitWasReported = false
    private var runtimeRestartExpected: TerminalRuntimeSessionInfo?
    private var runtimeInputQueue: TerminalRuntimeInputQueue?
    private var runtimeLaunchContext: (TerminalRuntimeLaunch, URL, URL)?
    private var runtimeReady: (() -> Void)?
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
    private var pendingShellIntegrationEvents: [(event: TerminalShellIntegrationEvent, commandID: UUID?)] = []
    private var runtimeParsingOffset: UInt64?
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
        guard session?.runtimeOwnsAgent != true else { return }
        guard case .localShell = session?.launchConfiguration else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastAgentSampleUptime >= 1 else { return }
        lastAgentSampleUptime = uptime
        guard didStart, terminalView.backendIsRunning else { return }
        let pid = runtimeHandle == nil ? tcgetpgrp(terminalView.backendChildFileDescriptor) : (runtimeForegroundPID ?? 0)
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
        TerminalAgentScreenReader.liveTail(terminalView)
    }

    init(session: TerminalSession) {
        self.session = session
        // The graphics cache is read once, when the terminal is created. The stored value is
        // available before the view exists, so the preference applies from the first frame.
        let cacheMegabytes = UserDefaults.standard.object(
            forKey: TerminalPreferences.Keys.imageCacheMegabytes
        ) as? Int ?? TerminalPreferences.defaultImageCacheMegabytes
        terminalView = FocusableLocalProcessTerminalView(
            frame: .zero,
            font: nil,
            options: TerminalGraphicsPolicy.terminalOptions(cacheMegabytes: cacheMegabytes)
        )
        super.init()
        configureViews()
    }

    func apply(preferences: TerminalPreferences) {
        self.preferences = preferences
        runtimeHandle?.configureReminders(.init(preferences: preferences))
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
        let normalized = TerminalPreferences.clampedScrollbackLines(lines)
        guard terminalView.appliedScrollbackLines != normalized else { return }
        terminalView.changeScrollback(normalized)
        terminalView.appliedScrollbackLines = normalized
    }

    private func applyGraphicsPolicy(cacheMegabytes: Int) {
        // The Kitty image cache and the sixel report are fixed when the terminal is created,
        // and SwiftTerm 1.99 no longer exposes the terminal for later changes. The view is
        // built with the policy already applied.
        _ = cacheMegabytes
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

    func terminate(preservingRuntime: Bool = false) {
        if !preservingRuntime { session?.releaseAIControl(reason: "terminal_closed") }
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
        startupPromptPollWorkItem?.cancel()
        pendingStartWorkItem?.cancel()
        runtimeReady = nil
        runtimeInputQueue?.cancel()
        if let runtimeHandle {
            if preservingRuntime { runtimeHandle.detach() } else { runtimeHandle.closeTerminal() }
        }
        else { terminalView.terminateOwnedProcess() }
    }

    func ensureProcessStarted() {
        if TerminalRuntimeService.isEnabled {
            startProcessIfNeeded()
            return
        }
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
              !terminalView.backendIsRunning else {
            return
        }
        guard prepareRuntimeSSHReconnect() else { return }
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

    /// A lost viewer is not evidence that the backend process has exited.
    private func prepareRuntimeSSHReconnect() -> Bool {
        guard let handle = runtimeHandle else { return true }
        guard let info = handle.info, !info.running else {
            session?.runtimeConnectionIssue = .disconnected
            return false
        }
        runtimeRestartExpected = info
        return true
    }

    func focusTerminal() {
        terminalView.requestFocus()
    }

    /// 自动聚焦（窗口挂载、视图刷新）：浮层接管键盘期间不抢第一响应者。
    /// 判定放在执行时，避免排队中的延迟聚焦在浮层打开之后才跑到。
    func focusTerminalAutomatically() {
        terminalView.requestAutomaticFocus()
    }

    /// 命令面板、AI 指令输入条等键盘浮层打开时置位，终端交还键盘。
    func setKeyboardOverlayActive(_ active: Bool) {
        terminalView.suppressesAutomaticFocus = active
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
        let style: CursorStyle
        switch shape {
        case .block:
            style = blink ? .blinkBlock : .steadyBlock
        case .bar:
            style = blink ? .blinkBar : .steadyBar
        case .underline:
            style = blink ? .blinkUnderline : .steadyUnderline
        }
        // 必须走视图的 setCursorStyle：它同时更新渲染器读取的光标样式和 caretView。
        // 只改 caretView 在 Metal 开启时对屏幕上的光标无效。
        terminalView.setCursorStyle(style)
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
            runtime: session?.runtimeInfo.map { .init(pid: $0.pid, generation: $0.generation,
                connected: runtimeHandle?.connected == true, errorCode: runtimeHandle?.lastError?.diagnosticCode,
                errorStage: runtimeHandle?.lastErrorStage, attachOnly: session?.runtimeAttachOnly == true ? true : nil,
                eventCursor: runtimeHandle?.eventCursor, outputRevision: $0.outputRevision, commands: $0.commands) },
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
            columns: terminalView.terminalDimensions.cols,
            rows: terminalView.terminalDimensions.rows,
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
    private var pendingRuntimeToolInputObserver: ((Result<Void, Error>) -> Void)?

    func mouseClickInputBytes(button: TerminalToolMouseButton, column: Int, row: Int) throws -> [UInt8] {
        guard terminalView.allowMouseReporting,
              let inputState = terminalView.terminalInputStateSnapshot(),
              inputState.mouseMode != .off else {
            throw TerminalToolError.mouseReportingUnavailable
        }
        let dimensions = inputState.dimensions
        guard column >= 1, column <= dimensions.cols, row >= 1, row <= dimensions.rows else {
            throw TerminalToolError.mousePositionOutOfBounds
        }
        guard let bytes = try terminalView.captureMouseClickReports(
            button: button.swiftTermButton, column: column - 1, row: row - 1
        ) else {
            throw TerminalToolError.mouseReportingUnavailable
        }
        return bytes
    }

    func sendToolInput(bytes: [UInt8], owner: String? = nil) throws {
        // A runtime-backed session has no local PTY to write. Callers that can
        // wait for the service ACK use the completion overload; this one only
        // serves the direct process path, so failing here is a caller bug.
        guard runtimeHandle == nil else { throw TerminalAIControlError.inputRejected }
        try session?.authorizeAIInput(owner: owner)
        guard didStart, terminalView.backendIsRunning else {
            throw TerminalToolError.processUnavailable
        }
        guard activeSessionTunnel == nil else {
            throw TerminalToolError.sessionTunnelActive
        }
        if runtimeHandle == nil { try session?.archiveAIInput(bytes, echoEnabled: terminalView.terminalEchoEnabled) }
        isSendingToolInput = true
        toolInputOwner = owner
        defer {
            isSendingToolInput = false
            toolInputOwner = nil
        }
        sendProcessInput(bytes: bytes)
        guard terminalView.didSendLastInput else { throw TerminalAIControlError.inputRejected }
    }

    func sendToolInput(bytes: [UInt8], owner: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard runtimeHandle != nil else {
                try sendToolInput(bytes: bytes, owner: owner)
                completion(.success(())); return
            }
            try enqueueRuntimeToolInput(bytes, owner: owner, completion: completion)
        } catch { completion(.failure(error)) }
    }

    /// Puts AI input onto the runtime queue and returns once it is accepted.
    /// The write itself finishes later: the service ACK is delivered on the main
    /// queue, so a caller already on the main thread cannot wait for it.
    /// `completion` replaces the observer installed by `observePendingRuntimeToolInput`.
    /// `afterSettled` always runs once the write is acknowledged, so a lease taken
    /// only for this write can be released without swallowing the observer.
    func enqueueRuntimeToolInput(_ bytes: [UInt8], owner: String?,
                                 completion: ((Result<Void, Error>) -> Void)? = nil,
                                 afterSettled: (() -> Void)? = nil) throws {
        guard runtimeHandle != nil else { throw TerminalAIControlError.inputRejected }
        try session?.authorizeAIInput(owner: owner)
        guard didStart, terminalView.backendIsRunning else { throw TerminalToolError.processUnavailable }
        guard activeSessionTunnel == nil else { throw TerminalToolError.sessionTunnelActive }
        guard runtimeInputQueue?.enqueue(bytes, source: .ai, owner: owner, completion: { [weak self] result in
            let observer = self?.pendingRuntimeToolInputObserver
            self?.pendingRuntimeToolInputObserver = nil
            if let completion { completion(result) } else { observer?(result) }
            if case .failure(let error) = result { self?.runtimeInputFailed(error) }
            afterSettled?()
        }) == true else {
            throw TerminalAIControlError.inputRejected
        }
    }

    /// One observer for the runtime tool input that was queued without its own
    /// completion. A newer enqueue, or an enqueue that carries a completion,
    /// drops the previous observer: that write's failure still surfaces through
    /// `runtimeInputFailed`.
    func sendToolMouseInput(bytes: [UInt8], owner: String?) throws {
        guard runtimeHandle == nil else { throw TerminalAIControlError.inputRejected }
        try session?.authorizeAIInput(owner: owner)
        guard didStart, terminalView.backendIsRunning else { throw TerminalToolError.processUnavailable }
        guard activeSessionTunnel == nil else { throw TerminalToolError.sessionTunnelActive }
        guard activeZModemTransfer == nil, pendingZModemProbe == nil,
              !isAwaitingAutomaticUploadSelection else {
            throw TerminalAIControlError.inputRejected
        }
        terminalView.sendBackend(bytes[...])
        if let owner, session?.aiLease != nil {
            try session?.renewAIControl(owner: owner)
        }
    }

    func sendToolMouseInput(bytes: [UInt8], owner: String?,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard runtimeHandle != nil else {
                try sendToolMouseInput(bytes: bytes, owner: owner)
                completion(.success(()))
                return
            }
            try enqueueRuntimeToolMouseInput(bytes, owner: owner, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    private func enqueueRuntimeToolMouseInput(
        _ bytes: [UInt8],
        owner: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard runtimeHandle != nil else { throw TerminalAIControlError.inputRejected }
        try session?.authorizeAIInput(owner: owner)
        guard didStart, terminalView.backendIsRunning else { throw TerminalToolError.processUnavailable }
        guard activeSessionTunnel == nil else { throw TerminalToolError.sessionTunnelActive }
        guard activeZModemTransfer == nil, pendingZModemProbe == nil,
              !isAwaitingAutomaticUploadSelection else {
            throw TerminalAIControlError.inputRejected
        }
        guard runtimeInputQueue?.enqueue(bytes, source: .ai, owner: owner, isMouseEvent: true,
            completion: { [weak self] result in
                if case .failure(let error) = result { self?.runtimeInputFailed(error) }
                completion(result)
            }) == true else {
            throw TerminalAIControlError.inputRejected
        }
    }

    func observePendingRuntimeToolInput(_ observer: @escaping (Result<Void, Error>) -> Void) {
        pendingRuntimeToolInputObserver = observer
    }

    func sendProcessInput(bytes: [UInt8]) {
        terminalView.send(source: terminalView, data: bytes[...])
    }

    var isProcessRunning: Bool {
        didStart && terminalView.backendIsRunning
    }

    var hasForegroundProcess: Bool {
        guard isProcessRunning else { return false }
        if let runtimeHandle, !runtimeHandle.connected { return true }

        let foregroundPID: pid_t
        let shellPID: pid_t
        if runtimeHandle == nil {
            foregroundPID = tcgetpgrp(terminalView.backendChildFileDescriptor)
            shellPID = terminalView.backendShellPID
        } else {
            foregroundPID = runtimeForegroundPID ?? 0
            shellPID = session?.runtimeInfo?.pid ?? 0
        }

        // Keep confirmation enabled when the PTY cannot report its process group.
        guard foregroundPID > 0, shellPID > 0 else { return true }
        return foregroundPID != shellPID
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
        guard didStart, terminalView.backendIsRunning else {
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
        guard didStart, terminalView.backendIsRunning else {
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
        guard didStart, terminalView.backendIsRunning else {
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
                          self.terminalView.backendIsRunning else {
                        return
                    }
                    self.terminalView.sendBackend(bytes[...])
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
                    if !usesUITestFixture, self.terminalView.backendIsRunning {
                        self.terminalView.sendBackend([0x0D][...])
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
        guard !terminalView.backendIsRunning else {
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
            self?.session?.onPaneFocus?()
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
        terminalView.onPreviewFile = { [weak self] url in
            guard let source = self?.session else { return }
            TerminalPreviewCenter.shared.open(source: source, url: url)
        }
        terminalView.onPreviewMarkdown = { [weak self] text in
            guard let source = self?.session else { return }
            TerminalPreviewCenter.shared.open(source: source, text: text)
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
            if self.runtimeHandle != nil {
                return true // Recording and command inference wait for the real PTY ACK.
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
        if let offset = runtimeParsingOffset, let handle = runtimeHandle,
           handle.features.contains(TerminalRuntimeLimits.commandLifecycleFeature), let generation = handle.info?.generation {
            pendingShellIntegrationEvents.append(contentsOf: shellIntegrationParser.acceptLocated(data, at: offset).map {
                ($0.event, TerminalRuntimeCommandInfo.identity(generation: generation, markerOffset: $0.startOffset))
            })
        } else {
            pendingShellIntegrationEvents.append(contentsOf: shellIntegrationParser.accept(data).map { ($0, nil) })
        }
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
            switch event.event {
            case .commandStarted(let command):
                session?.startShellIntegratedCommand(
                    command: command,
                    historySnapshot: historySnapshot,
                    commandID: event.commandID
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
                        guard let self, self.terminalView.backendIsRunning else { return }
                    self.terminalView.sendBackend(output[...])
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

        if let session, session.runtimeAttachOnly {
            finishStartupPromptDeduplication()
            startRuntime(.init(executable: "/museterm-attach-existing-only", directory: "/"),
                root: session.runtimeRecoveryRoot ?? TerminalRuntimeService.rootDirectory) { [weak session] in
                session?.markStartupCommandsFinished()
            }
            return
        }

        switch session?.launchConfiguration ?? .localShell() {
        case .localShell(let startDirectory, let profile):
            let descriptor = Self.localShellLaunchDescriptor(profile: profile)
            let currentDirectory = TerminalWorkingDirectory.normalizedExistingDirectory(startDirectory)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            session?.updateShellName(descriptor.shellName)
            // 先盖上遮罩，再启动进程：保证 shell 的第一条 PS1 输出抵达前画面已被遮住。
            beginStartupPromptDeduplication()
            session?.beginProcessRun()
            if TerminalRuntimeService.isEnabled {
                startRuntime(.init(executable: descriptor.executable, arguments: descriptor.args,
                    executableName: descriptor.execName, environment: Self.runtimeEnvironment(descriptor.environment),
                    directory: currentDirectory,
                    columns: canStartProcess ? max(1, terminalColumns) : TerminalRuntimeLimits.defaultColumns,
                    rows: canStartProcess ? max(1, terminalRows) : TerminalRuntimeLimits.defaultRows)) { [weak self] in
                    if let profile { self?.drainStartupCommands(profile.normalized.startupCommands) }
                    else { self?.session?.markStartupCommandsFinished() }
                }
                return
            }
            terminalView.startOwnedProcess(
                executable: descriptor.executable,
                args: descriptor.args,
                environment: session?.nativeAgentEnvironment(descriptor.environment) ?? descriptor.environment,
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
                if TerminalRuntimeService.isEnabled || runtimeHandle != nil {
                    let startup = [RemoteShellIntegration.shellProbeCommand] + RemoteShellIntegration.startupCommands(for: profile) + descriptor.startupCommands
                    startRuntime(.init(executable: descriptor.executable, arguments: descriptor.args,
                        environment: Self.runtimeEnvironment(Self.environmentArray(shellPath: nil)),
                        directory: FileManager.default.homeDirectoryForCurrentUser.path,
                        columns: canStartProcess ? max(1, terminalColumns) : TerminalRuntimeLimits.defaultColumns,
                        rows: canStartProcess ? max(1, terminalRows) : TerminalRuntimeLimits.defaultRows),
                        root: runtimeLaunchContext?.1 ?? TerminalRuntimeService.rootDirectory,
                        executable: runtimeLaunchContext?.2 ?? TerminalRuntimeService.executableURL) { [weak self] in self?.drainStartupCommands(startup) }
                    return
                }
                terminalView.startOwnedProcess(
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
                      !self.terminalView.backendIsRunning else {
                    return
                }
                self.terminalView.feed(text: "\(L10n.format("ssh.reconnect.attempting", attempt))\n")
                guard self.prepareRuntimeSSHReconnect() else { return }
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
                    guard let self, self.terminalView.backendIsRunning else { return }
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
        guard terminalView.backendIsRunning else { return }
        if let runtimeHandle {
            runtimeHandle.resize(columns: newCols, rows: newRows)
            noteStartupOutputActivity()
            return
        }
        var size = terminalView.getWindowSize()
        let _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: terminalView.backendChildFileDescriptor,
            windowSize: &size
        )
        // 启动期的窗口定型 resize 会向 shell 发 SIGWINCH 触发重绘（首个标签尤其晚），
        // 把它也算作“活动”，让遮罩继续盖住并等它引发的重绘安静后再判定，避免过早揭幕。
        noteStartupOutputActivity()
        sizeChanged(source: terminalView, newCols: newCols, newRows: newRows)
    }

    private static func runtimeEnvironment(_ entries: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        result["MUSETERM_AGENT_CONTEXT"] = nil // The service creates and owns the bootstrap.
        result["QTERM_AGENT_CONTEXT"] = nil
        return result
    }

    func startRuntime(_ launch: TerminalRuntimeLaunch, root: URL = TerminalRuntimeService.rootDirectory,
                      executable: URL = TerminalRuntimeService.executableURL,
                      restarting previous: TerminalRuntimeSessionInfo? = nil, ready: @escaping () -> Void) {
        guard let session else { return }
        var launch = launch
        if let preferences { launch.reminderPolicy = .init(preferences: preferences) }
        let restarting = previous ?? runtimeRestartExpected
        runtimeRestartExpected = nil
        let restoring = restarting == nil && (session.runtimeRequiresExisting || session.runtimeGenerationToRestore != nil)
        let restoredLocalShell = session.runtimeRestoresLocalShell
        let recoverMissingLocalShell = restoring && restoredLocalShell
        if restoring { finishStartupPromptDeduplication() }
        didStart = true
        runtimeLaunchContext = (launch, root, executable)
        runtimeReady = ready
        runtimeInputQueue?.cancel()
        runtimeHandle?.detach()
        runtimeExitWasReported = false
        runtimeInputErrorCode = nil
        let handle = TerminalRuntimeSessionHandle(id: session.id, root: root, executable: executable)
        runtimeHandle = handle
        let requiredExistingBeforeCreate = session.runtimeRequiresExisting
        handle.onCreationRequested = { [weak self, weak handle, weak session] epoch in
            guard let self, let handle, self.runtimeHandle === handle, let session else {
                throw TerminalRuntimeConnectionError.unavailable
            }
            let previousEpoch = session.runtimePendingCreationEpoch
            let previousRequirement = session.runtimeRequiresExisting
            session.runtimePendingCreationEpoch = epoch
            session.runtimeRequiresExisting = epoch != nil || requiredExistingBeforeCreate
            do { try session.onRuntimeCreationChanged?() }
            catch {
                session.runtimePendingCreationEpoch = previousEpoch
                session.runtimeRequiresExisting = previousRequirement
                throw error
            }
        }
        handle.onRenderedOutput = { [weak session] in session?.onRuntimeOutputRendered?() }
        session.runtimeConnectionIssue = .connecting
        terminalView.externalIsRunning = { [weak handle] in handle?.info?.running == true }
        // Trusted transport bytes (tunnel/ZMODEM/redraw) retain the old direct
        // backend path. They are never command text or recording input. The
        // service still enforces generation, human ownership and bounded input.
        terminalView.externalBackendSend = { [weak self, weak handle] bytes in
            guard let self, let handle, self.runtimeHandle === handle else { return false }
            return handle.send(Data(bytes), source: .human) { [weak self, weak handle] result in
                guard let self, let handle, self.runtimeHandle === handle else { return }
                if case .failure(let error) = result { self.runtimeInputFailed(error) }
            }
        }
        runtimeInputQueue = TerminalRuntimeInputQueue(handle: handle, approve: { [weak self, weak handle] bytes, echo, source, owner in
            guard let self, let handle, self.runtimeHandle === handle else { return false }
            self.isSendingToolInput = source == .ai
            self.toolInputOwner = owner
            defer { self.isSendingToolInput = false; self.toolInputOwner = nil }
            return self.terminalView.onSendToProcess?(bytes, echo) ?? false
        }, committed: { [weak self, weak handle] bytes, source, response in
            guard let self, let handle, self.runtimeHandle === handle else { return }
            self.runtimeInputErrorCode = nil
            if self.session?.runtimeConnectionIssue == .inputRejected || self.session?.runtimeConnectionIssue == .inputTooLarge {
                self.session?.runtimeConnectionIssue = nil
            }
            let echo = response.echoEnabled == true
            self.session?.recordInputIfNeeded(data: bytes, echoEnabled: echo)
            self.session?.observeProcessInput(data: bytes, echoEnabled: echo, historySnapshot: self.fullHistoryText())
            self.updatePendingSafetyInput(data: bytes, echoEnabled: echo)
            if source == .ai {
                do { try self.session?.archiveAIInput(bytes, echoEnabled: echo) }
                catch { NSLog("MuseTerm runtime input archive failed") }
            }
        }, failed: { [weak self, weak handle] error in
            guard let self, let handle, self.runtimeHandle === handle else { return }
            self.runtimeInputFailed(error)
        }, approveMouseEvent: { [weak self, weak handle] owner in
            guard let self, let handle, self.runtimeHandle === handle,
                  self.didStart, self.terminalView.backendIsRunning,
                  self.activeSessionTunnel == nil,
                  self.activeZModemTransfer == nil,
                  self.pendingZModemProbe == nil,
                  !self.isAwaitingAutomaticUploadSelection else { return false }
            do {
                try self.session?.authorizeAIInput(owner: owner)
                return true
            } catch {
                return false
            }
        }, committedMouseEvent: { [weak self, weak handle] _ in
            guard let self, let handle, self.runtimeHandle === handle else { return }
            self.runtimeInputErrorCode = nil
            if self.session?.runtimeConnectionIssue == .inputRejected
                || self.session?.runtimeConnectionIssue == .inputTooLarge {
                self.session?.runtimeConnectionIssue = nil
            }
        })
        terminalView.externalSend = { [weak self, weak handle] bytes, protocolTraffic in
            guard let self, let handle else { return false }
            if protocolTraffic {
                let data = Data(bytes)
                guard TerminalRuntimeReplyPolicy.allows(data) else { return false }
                return handle.send(data, source: .protocolReply)
            }
            let accepted = self.runtimeInputQueue?.enqueue(bytes, source: .human, owner: nil) == true
            if !accepted, !handle.reconnecting {
                self.session?.runtimeConnectionIssue = TerminalRuntimeInputQueue.rejectedEnqueueIssue(
                    connected: handle.connected, byteCount: bytes.count)
            }
            return accepted
        }
        terminalView.externalPaste = { [weak self, weak handle] bytes, text in
            guard let self, let handle, self.runtimeHandle === handle else { return false }
            let accepted = self.runtimeInputQueue?.enqueue(bytes, source: .human, owner: nil, validationBytes: text) == true
            if !accepted {
                self.session?.runtimeConnectionIssue = TerminalRuntimeInputQueue.rejectedEnqueueIssue(
                    connected: handle.connected, byteCount: bytes.count)
            }
            return accepted
        }
        var didSynchronizeInitialSize = false
        handle.onState = { [weak self, weak handle] info in
            guard let self, let handle, self.runtimeHandle === handle, let session = self.session else { return }
            let dimensions = self.terminalView.terminalDimensions
            if !didSynchronizeInitialSize, self.canStartProcess, info.running,
               dimensions.cols > 0, dimensions.rows > 0 {
                // Layout may have completed before a backend existed, when the
                // resize callback intentionally skipped the unavailable PTY.
                didSynchronizeInitialSize = true
                if info.columns != dimensions.cols || info.rows != dimensions.rows {
                    handle.resize(columns: dimensions.cols, rows: dimensions.rows)
                }
            }
            if !handle.createdNewPTY { self.finishStartupPromptDeduplication() }
            session.runtimeOwnsTerminalAttention = handle.features.contains(TerminalRuntimeLimits.terminalAttentionFeature)
            if session.runtimeOwnsTerminalAttention { session.attentionStore?.markRuntimeAuthorityExternal(tabID: session.id) }
            else if info.agent != nil || session.runtimeOwnsAgent { session.attentionStore?.markAgentAuthorityExternal(tabID: session.id) }
            if let preferences = self.preferences { handle.configureReminders(.init(preferences: preferences)) }
            session.runtimeRestoreHidden = false
            session.runtimeRequiresExisting = true
            session.runtimeRestoresLocalShell = false
            if recoverMissingLocalShell && handle.createdNewPTY && session.runtimeInfo == nil {
                session.runtimeSessionWasReopened = true
            }
            session.applyRuntimeInfo(info)
            if !info.running && !self.runtimeExitWasReported {
                self.runtimeExitWasReported = true
                self.processTerminated(source: self.terminalView, exitCode: info.exitStatus)
            }
        }
        var didBecomeReady = false
        handle.onOutput = { [weak self, weak handle] response, historicalBytes, consumed in
            guard let self, let handle, self.runtimeHandle === handle, let session = self.session else { consumed(); return }
            self.runtimeForegroundPID = response.foregroundPID
            if response.hasGap == true { session.runtimeConnectionIssue = .outputGap }
            else if session.runtimeConnectionIssue != .inputRejected && session.runtimeConnectionIssue != .inputTooLarge {
                session.runtimeConnectionIssue = nil
            }
            if session.runtimeOwnsAgent || session.runtimeOwnsTerminalAttention {
                session.attentionStore?.adoptAgentItems(response.attention ?? [], tabID: session.id, cursor: response.eventHead)
            }
            if response.hasGap == true {
                self.terminalView.beginTruncatedRuntimeReplay()
                self.terminalView.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H")
            }
            let data = response.data ?? Data()
            if let end = response.cursor?.offset, end >= UInt64(data.count) {
                self.runtimeParsingOffset = end - UInt64(data.count) + UInt64(min(data.count, max(0, historicalBytes)))
            }
            self.terminalView.receiveExternal(data, historicalBytes: historicalBytes, completion: consumed)
            self.runtimeParsingOffset = nil
            if !didBecomeReady {
                didBecomeReady = true
                let ready = self.runtimeReady; self.runtimeReady = nil
                if restoring || restoredLocalShell || !handle.createdNewPTY { session.markStartupCommandsFinished() } else { ready?() }
            }
        }
        handle.onFailure = { [weak self, weak handle, weak session] error in
            guard let self, let handle, self.runtimeHandle === handle else { return }
            if case TerminalRuntimeConnectionError.sessionMissing = error {
                session?.runtimeConnectionIssue = .sessionEnded
                session?.state = .exited(nil)
            } else {
                session?.runtimeConnectionIssue = .disconnected
            }
            // Keep recovery actions visible; hiding a failed leaf also hid its
            // healthy siblings and left the selected canvas without a terminal.
            session?.runtimeRestoreHidden = false
        }
        handle.onRecovering = { [weak self, weak handle] in
            guard let self, let handle, self.runtimeHandle === handle else { return }
            // A slow parse and a manual reconnect both come through here. Neither
            // means the backend is gone, so the banner has to come down at once
            // instead of waiting for the next frame to finish rendering.
            if self.session?.runtimeConnectionIssue == .disconnected
                || self.session?.runtimeConnectionIssue == .connecting {
                self.session?.runtimeConnectionIssue = nil
            }
        }
        session.attentionStore?.externalAcknowledgement[session.id] = { [weak handle, weak session] id, version in
            guard let handle, handle.connected else { return false }
            handle.acknowledge(id: id, version: version) { result in
                if case .failure(TerminalRuntimeConnectionError.rejected(let code)) = result,
                   code == TerminalRuntimeSessionHandle.acknowledgementPendingCode { return }
                if case .success(let response) = result, let session {
                    session.attentionStore?.adoptAgentItems(response.attention ?? [], tabID: session.id, cursor: response.eventHead)
                } else { session?.runtimeConnectionIssue = .disconnected }
            }
            return true
        }
        handle.start(launch, restoring: restarting == nil ? session.runtimeGenerationToRestore : nil, existingOnly: restoring,
            renderedCursor: restarting == nil ? session.runtimeRenderedCursorToRestore : nil, restarting: restarting,
            recoverMissingLocalShell: recoverMissingLocalShell, pendingCreationEpoch: session.runtimePendingCreationEpoch)
    }

    private func runtimeInputFailed(_ error: Error) {
        runtimeInputErrorCode = (error as? TerminalRuntimeConnectionError)?.diagnosticCode ?? "input_rejected"
        if error is TerminalAIControlError { session?.runtimeConnectionIssue = .inputRejected }
        else if case TerminalRuntimeConnectionError.rejected = error { session?.runtimeConnectionIssue = .inputRejected }
        else { session?.runtimeConnectionIssue = .disconnected }
    }

    func reconnectRuntime() {
        if runtimeHandle?.info == nil, let (launch, root, executable) = runtimeLaunchContext {
            startRuntime(launch, root: root, executable: executable, ready: runtimeReady ?? {})
        } else { runtimeHandle?.reconnect() }
    }

    func detachRuntimeViewer() { runtimeHandle?.detach() }

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
        guard terminalView.backendIsRunning else {
            finishStartupPromptDeduplication()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now >= startupHardDeadline {
            // 到硬上限，最后再尝试清一次（若仍重复），然后无论如何揭开。
            if startupRedrawCount < 3, visibleScreenLooksLikeDuplicatedStartupPrompt() {
                terminalView.sendBackend([0x0C][...])
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
            terminalView.sendBackend([0x0C][...])
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
        let rows = terminalView.terminalDimensions.rows
        guard rows > 0 else { return "" }
        return terminalView.visibleRowsText(0..<rows).joined(separator: "\n")
    }

    var terminalColumns: Int {
        terminalView.terminalDimensions.cols
    }

    var terminalRows: Int {
        terminalView.terminalDimensions.rows
    }

    private func fullHistoryText() -> String {
        let data = terminalView.getBufferAsData()
        guard !data.isEmpty else { return visibleScreenText() }
        return String(data: data, encoding: .utf8) ?? visibleScreenText()
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
        environment["MUSETERM_AGENT_CONTEXT"] = nil
        environment["QTERM_AGENT_CONTEXT"] = nil
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
