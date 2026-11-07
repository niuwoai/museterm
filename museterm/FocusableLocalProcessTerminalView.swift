import AppKit
import Darwin
import MetalKit
import SwiftTerm
import SwiftUI

final class FocusableLocalProcessTerminalView: LocalProcessTerminalView {
    var externalIsRunning: (() -> Bool)?
    var externalSend: (([UInt8], Bool) -> Bool)?
    var externalPaste: ((_ framedBytes: [UInt8], _ textBytes: [UInt8]) -> Bool)?
    var externalBackendSend: (([UInt8]) -> Bool)?
    private var externalFeedCompletion: (() -> Void)?
    private(set) var isReplayingHistoricalOutput = false
    private var historicalFeedRanges: [Range<Int>] = []
    private var replayScreenModeUnknown = false
    private var clearOrphanedReplayScreen = false
    private var lastParsedRuntimeByte: UInt8?
    var backendIsRunning: Bool { externalIsRunning?() ?? (ownedProcess?.running ?? process.running) }
    /// The PTY master descriptor of whichever process is actually running: our own when the
    /// view launched it, otherwise the one SwiftTerm created for the view.
    var backendChildFileDescriptor: Int32 { (ownedProcess ?? process).childfd }
    var backendShellPID: pid_t { (ownedProcess ?? process).shellPid }

    /// The process whose output we parse ourselves. SwiftTerm 1.99 feeds the view's built-in
    /// process straight into the parser on its IO thread, so anything that has to look at the
    /// bytes first (ZMODEM, the session tunnel, SSH diagnostics) needs a process we own.
    private var ownedProcess: LocalProcess?
    private var ownedProcessDelegate: OwnedProcessDelegate?
    /// The scrollback last applied through the view. The terminal keeps the value internally
    /// and no longer exposes it for comparison.
    var appliedScrollbackLines: Int?

    /// Starts the shell on a process this view owns. The view's built-in process parses on its
    /// own IO thread and never returns the bytes, so it cannot serve the output interceptors.
    func startOwnedProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil) {
        let delegate = OwnedProcessDelegate(owner: self)
        ownedProcessDelegate = delegate
        let owned = LocalProcess(delegate: delegate, dispatchQueue: .main)
        ownedProcess = owned
        owned.startProcess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
    }

    func terminateOwnedProcess() {
        if let ownedProcess {
            ownedProcess.terminate()
        } else {
            terminate()
        }
    }
    /// 命令面板 / AI 指令输入条等键盘浮层打开期间为 true：此时终端不得自动夺取
    /// 第一响应者，键盘输入应留在浮层里。鼠标点击等显式动作仍走 requestFocus()。
    var suppressesAutomaticFocus = false

    func beginTruncatedRuntimeReplay() {
        // A truncated VT stream may have lost its alternate-screen entry.
        // Keep an already-known alternate buffer's saved normal screen intact.
        replayScreenModeUnknown = terminalInputStateSnapshot()?.isAlternateBuffer != true
    }

    // SwiftTerm 1.99 delivers terminal callbacks from the parser thread and
    // hops back to main itself. The override has to stay nonisolated to match,
    // and every touch of view state goes through the same hop.
    nonisolated override func bufferActivated(source: Terminal) {
        // The parser calls this with the terminal lock held, and the lock is not
        // re-entrant, so the replay recovery has to happen after the feed that
        // triggered the switch returns. When the feed itself runs on the main
        // thread (our own replay path) a queued block would land too late: the
        // caller reads the screen the moment the feed returns. Running inline on
        // the main thread keeps that synchronous, and defers it otherwise.
        let alternate = source.isCurrentBufferAlternate
        let apply = { [weak self] in
            guard let self else { return }
            if self.replayScreenModeUnknown {
                self.replayScreenModeUnknown = false
                self.clearOrphanedReplayScreen = !alternate
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async(execute: apply)
        }
        super.bufferActivated(source: source)
    }

    func sendBackend(_ bytes: ArraySlice<UInt8>) {
        if let externalBackendSend { _ = externalBackendSend(Array(bytes)) }
        else if let externalSend { _ = externalSend(Array(bytes), false) }
        else { (ownedProcess ?? process).send(data: bytes) }
    }

    func receiveExternal(_ data: Data, historicalBytes: Int = 0, completion: @escaping () -> Void) {
        externalFeedCompletion = completion
        let bytes = Array(data)
        let historyCount = min(bytes.count, max(0, historicalBytes))
        if historyCount > 0 {
            let start = pendingFeedBytes.count
            historicalFeedRanges.append(start..<(start + historyCount))
            isReplayingHistoricalOutput = true
            acceptOutput(bytes[..<historyCount])
            isReplayingHistoricalOutput = false
        }
        if historyCount < bytes.count { acceptOutput(bytes[historyCount...]) }
        if pendingFeedBytes.isEmpty {
            externalFeedCompletion = nil
            completion()
        }
    }
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
    var onPreviewFile: ((URL) -> Void)?
    var onPreviewMarkdown: ((String) -> Void)?
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
    private var capturedMouseReports: [[UInt8]]?
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
    #if DEBUG
    /// While set, a runtime frame is parsed but its completion is held back, so
    /// tests can observe a subscription whose consumer acknowledgement is late.
    /// Clearing it resumes the frame that is waiting, and a frame still queued
    /// behind the parser completes normally on its own flush.
    var holdExternalFeedCompletionForTesting = false {
        didSet {
            guard !holdExternalFeedCompletionForTesting else { return }
            // The flag flips from a test that is already on the main thread, and
            // the reader it unblocks calls straight back into the view. Releasing
            // on the next turn keeps that re-entry off this stack.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.holdExternalFeedCompletionForTesting else { return }
                let held = self.heldExternalFeedCompletion
                self.heldExternalFeedCompletion = nil
                held?()
            }
        }
    }
    private var heldExternalFeedCompletion: (() -> Void)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        installTerminalDelegateRouter()
        installIMEReturnMonitor()
    }

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
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
        // Mouse reports and emulator replies go through the delegate, and the local
        // process view is the only thing that writes them to the child. Installing
        // the router above replaces it, so keep its path and hand reports to it once
        // this view's own checks have run.
        processInput = { [weak self] bytes in
            self?.sendBackend(bytes)
        }
        // SwiftTerm 1.99 routes keystrokes, paste and send(txt:) through the input
        // sender straight to its built-in process, which skips the delegate and so
        // skips every guard this view keeps on user input. Its setup() installs that
        // delivery before this init body runs; replace it so those bytes come back
        // through the delegate, where the guards live. Mouse reports and emulator
        // replies never use the input sender, so they are unaffected.
        inputSender.replaceDelivery { [weak self] bytes in
            guard let self else { return }
            self.terminalDelegate?.send(source: self, data: bytes[...])
        }
    }


    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopSelectionAutoscroll()
        }
        DispatchQueue.main.async { [weak self] in
            self?.requestAutomaticFocus()
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

    func captureMouseClickReports(button: Int, column: Int, row: Int) -> [UInt8]? {
        guard capturedMouseReports == nil,
              allowMouseReporting,
              let mouseMode = terminalInputStateSnapshot()?.mouseMode,
              mouseMode.sendButtonPress() else { return nil }
        capturedMouseReports = []
        defer { capturedMouseReports = nil }
        sendMouseEvent(button: button, release: false, col: column, row: row)
        if mouseMode.sendButtonRelease() {
            sendMouseEvent(button: button, release: true, col: column, row: row)
        }
        let reports = capturedMouseReports ?? []
        guard !reports.isEmpty, reports.count <= 2,
              reports.allSatisfy({ TerminalMouseReportPolicy.isMouseReport($0[...]) }) else { return nil }
        return reports.flatMap { $0 }
    }

    /// 自动聚焦入口：浮层接管键盘时让路。显式用户动作（点击、粘贴）用 requestFocus()。
    func requestAutomaticFocus() {
        guard !suppressesAutomaticFocus else { return }
        requestFocus()
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

    nonisolated override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        DispatchQueue.main.async { [weak self] in
            self?.noteSelectionChanged()
        }
    }

    private func noteSelectionChanged() {
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
        let preview = NSMenuItem(title: L10n.string("preview.selection_action"), action: #selector(previewSelectedMarkdown), keyEquivalent: "")
        preview.target = self
        preview.representedObject = context.trimmedText
        menu.addItem(preview)
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

    @objc private func previewSelectedMarkdown(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onPreviewMarkdown?(text)
    }

    private func openLocalItem(_ url: URL) {
        if TerminalPreviewLoader.supports(url), let onPreviewFile { onPreviewFile(url) }
        else { NSWorkspace.shared.open(url) }
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
        guard externalPaste != nil else { super.paste(sender); return }
        _ = sendPaste(NSPasteboard.general.string(forType: .string) ?? "")
    }

    /// Preserve one user decision and one write ACK for the complete paste.
    /// Validation/recording use text only; the PTY receives the complete frame.
    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        didSendLastInput = false
        guard !isReplayingHistoricalOutput, !text.isEmpty, let externalPaste else { return false }
        unmarkText()
        let textBytes = Array(text.utf8)
        let framed = terminalInputStateSnapshot()?.bracketedPasteMode == true
            ? EscapeSequences.bracketedPasteStart + textBytes + EscapeSequences.bracketedPasteEnd
            : textBytes
        guard externalPaste(framed, textBytes) else { return false }
        onProcessInputSent?()
        didSendLastInput = true
        return true
    }

    private(set) var didSendLastInput = false

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        didSendLastInput = false
        guard !isReplayingHistoricalOutput else { return }
        let bytes = Array(data)
        if capturedMouseReports != nil {
            guard capturedMouseReports?.count ?? 0 < 2,
                  TerminalMouseReportPolicy.isMouseReport(bytes[...]) else { return }
            capturedMouseReports?.append(bytes)
            return
        }
        if let externalSend {
            guard externalSend(bytes, false) else { return }
            onProcessInputSent?()
            didSendLastInput = true
            return
        }
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
    // The parser calls this with the terminal lock held. The lock is not re-entrant, so
    // the delivery, which takes the lock again on its way to the process, has to wait
    // until the callback returns. A main-thread caller (the view's own mouse handling)
    // reads the result the moment it returns, so that case runs inline; a parser-thread
    // caller hops to the main queue instead. The bytes are copied first because the
    // slice only lives for the duration of the call.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let deliver = { [weak self] in
            self?.deliverEmulatorReply(bytes[...])
            return
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(deliver)
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func deliverEmulatorReply(_ data: ArraySlice<UInt8>) {
        guard !isReplayingHistoricalOutput else { return }
        if TerminalMouseReportPolicy.isMouseReport(data) {
            send(source: self, data: data)
            return
        }
        if let externalSend { _ = externalSend(Array(data), true); return }
        super.send(source: self, data: data)
    }

    fileprivate func terminalDidResize(newCols: Int, newRows: Int) {
        pendingResizeWorkItem?.cancel()
        guard backendIsRunning else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.backendIsRunning else { return }
            let dimensions = self.terminalDimensions
            guard dimensions.cols == newCols, dimensions.rows == newRows else {
                self.terminalDidResize(newCols: dimensions.cols, newRows: dimensions.rows)
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
        guard !isReplayingHistoricalOutput else { return }
        guard let string = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([string as NSString])
    }

    fileprivate func terminalClipboardData() -> Data? {
        guard !isReplayingHistoricalOutput else { return nil }
        return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
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
            openLocalItem(url)
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
            openLocalItem(url)
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
        let dimensions = terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        let cellHeight = getOptimalFrameSize().height / CGFloat(dimensions.rows)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let glyph = font.glyph(withName: "W")
        let cellWidth = ceil(font.advancement(forGlyph: glyph).width * scale) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / cellWidth)
        let row = Int((frame.height - point.y) / cellHeight)
        guard (0..<dimensions.cols).contains(column), (0..<dimensions.rows).contains(row) else { return nil }
        return (column, row)
    }

    /// 一格一个字符，下标与列号对齐；空格子和宽字符的占位格读出来是空串，按分隔符处理。
    /// 文本来自视图的内容快照：SwiftTerm 1.99 起可变的 terminal 不再对外可见。
    private func screenRowCharacters(row: Int) -> [Character]? {
        guard let snapshot = terminalContentSnapshot(region: .viewport) else { return nil }
        let dimensions = snapshot.inputState.dimensions
        guard (0..<dimensions.rows).contains(row) else { return nil }
        let absoluteRow = snapshot.liveTopRow + row
        guard let copied = snapshot.rows.first(where: { $0.absoluteRow == absoluteRow }) else { return nil }
        return (0..<dimensions.cols).map { column in
            guard column < copied.cells.count else { return "\u{0}" }
            let cell = copied.cells[column]
            guard cell.width > 0, let character = cell.text.first else { return "\u{0}" }
            return character
        }
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
                if let preview = self?.onPreviewFile { preview(fileURL) }
                else { NSWorkspace.shared.open(fileURL) }
            case .failure(let error):
                // 只记 host + path，query 里可能带 token
                NSLog("MuseTerm image link download failed host=%@ path=%@ error=%@", url.host ?? "", url.path, String(describing: error))
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
        guard !isReplayingHistoricalOutput else { return }
        NSSound.beep()
        onTerminalBell?()
    }

    fileprivate func ownedProcessDelivered(_ slice: ArraySlice<UInt8>) {
        acceptOutput(slice)
    }

    fileprivate func ownedProcessTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === ownedProcess else { return }
        ownedProcess = nil
        ownedProcessDelegate = nil
        processTerminated(source, exitCode: exitCode)
    }

    fileprivate func ownedProcessFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        guard source === ownedProcess else { return }
        ownedProcess = nil
        ownedProcessDelegate = nil
        processFailedToStart(source, error: error)
    }



    /// 接收一段待解析的输出。SwiftTerm 1.99 把解析搬到了进程的 IO 线程，并把
    /// `LocalProcessTerminalView.dataReceived(slice:)` 标成不可用，所以这里改成自己的入口：
    /// 回放历史输出走它，真实进程的输出由我们自己的 `LocalProcess` 回调进来。
    private func acceptOutput(_ slice: ArraySlice<UInt8>) {
        if !isReplayingHistoricalOutput, onReceivedProcessData?(slice) == true {
            return
        }
        if !isReplayingHistoricalOutput, shouldRecordInput?() == true, !isExpectedEcho(slice) {
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
        var offset = 0
        for history in historicalFeedRanges where history.lowerBound < end {
            let start = max(offset, history.lowerBound)
            if offset < start { feedPendingRange(offset..<start, historical: false) }
            let stop = min(end, history.upperBound)
            if start < stop { feedPendingRange(start..<stop, historical: true) }
            offset = stop
        }
        if offset < end { feedPendingRange(offset..<end, historical: false) }
        historicalFeedRanges = historicalFeedRanges.compactMap { range in
            guard range.upperBound > end else { return nil }
            return max(0, range.lowerBound - end)..<(range.upperBound - end)
        }
        pendingFeedBytes.removeFirst(end)
        onProcessOutputCommitted?()
        // 仍有积压 → 下一 tick 继续（让出 runloop 给 UI 事件，保持界面可响应）。
        if !pendingFeedBytes.isEmpty {
            scheduleFeedFlush()
        } else {
            let completion = externalFeedCompletion
            externalFeedCompletion = nil
            #if DEBUG
            if holdExternalFeedCompletionForTesting {
                heldExternalFeedCompletion = completion
            } else {
                completion?()
            }
            #else
            completion?()
            #endif
        }
    }

    private func feedPendingRange(_ range: Range<Int>, historical: Bool) {
        isReplayingHistoricalOutput = historical
        defer { isReplayingHistoricalOutput = false }
        var start = range.lowerBound
        if replayScreenModeUnknown {
            // DECRST ends in 'l'. Stop feeding at possible final bytes so the
            // emulator can recognize the real command (including split CSI),
            // then clean before any following shell output in the same frame.
            // Do not recursively feed from the parser's bufferActivated callback.
            for index in range where isPossibleScreenResetEnd(at: index, start: range.lowerBound) {
                feedPendingBytes(start..<(index + 1))
                start = index + 1
                finishReplayScreenRecovery()
                if !replayScreenModeUnknown { break }
            }
        }
        if start < range.upperBound { feedPendingBytes(start..<range.upperBound) }
        finishReplayScreenRecovery()
    }

    private func isPossibleScreenResetEnd(at index: Int, start: Int) -> Bool {
        guard pendingFeedBytes[index] == 0x6c else { return false }
        let previous = index > start ? pendingFeedBytes[index - 1] : lastParsedRuntimeByte
        return previous == 0x3b || previous.map { (0x30...0x39).contains($0) } == true
    }

    private func feedPendingBytes(_ range: Range<Int>) {
        feed(byteArray: pendingFeedBytes[range])
        lastParsedRuntimeByte = pendingFeedBytes[range.upperBound - 1]
    }

    private func finishReplayScreenRecovery() {
        guard clearOrphanedReplayScreen else { return }
        clearOrphanedReplayScreen = false
        // Erase only the uncertain viewport. Keep cursor state, scrollback,
        // process identity and subsequent shell output; never inject PTY input.
        feed(text: "\u{1b}[2J")
    }

    var terminalEchoEnabled: Bool {
        if externalSend != nil { return false } // Only the service ACK permits recording.
        let backend = ownedProcess ?? process
        guard let backend, backend.running else { return false }
        var attributes = termios()
        guard tcgetattr(backend.childfd, &attributes) == 0 else { return false }
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

/// Receives the output of the process this view owns. It exists as its own type because
/// `LocalProcessTerminalView.dataReceived(slice:)` is unavailable, and a method of that name on
/// the view can no longer satisfy `LocalProcessDelegate`.
private final class OwnedProcessDelegate: LocalProcessDelegate {
    private weak var owner: FocusableLocalProcessTerminalView?

    init(owner: FocusableLocalProcessTerminalView) {
        self.owner = owner
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        owner?.ownedProcessDelivered(slice)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        owner?.ownedProcessTerminated(source, exitCode: exitCode)
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        owner?.ownedProcessFailedToStart(source, error: error)
    }

    func getWindowSize() -> winsize {
        owner?.getWindowSize() ?? winsize()
    }
}
