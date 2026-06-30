import AppKit
import Darwin
import SwiftTerm
import SwiftUI

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

    let container = NSView(frame: .zero)
    private let visualEffectView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let terminalLeadingMarginView = NSView(frame: .zero)
    private let terminalTrailingMarginView = NSView(frame: .zero)
    private let terminalView = FocusableLocalProcessTerminalView(frame: .zero)
    private weak var session: TerminalSession?
    private var didStart = false
    private var pendingStart = false
    private var didConfigureMetal = false
    private var lastAppliedPreferences: TerminalPreferenceSignature?

    init(session: TerminalSession) {
        self.session = session
        super.init()
        configureViews()
    }

    func apply(preferences: TerminalPreferences) {
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
        terminalView.customBlockGlyphs = true
        terminalView.antiAliasCustomBlockGlyphs = true
        terminalView.useBrightColors = true

        configureMetalIfNeeded()

        terminalView.needsDisplay = true
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
        startPendingProcessIfReady()
    }

    func terminate() {
        terminalView.terminate()
    }

    func ensureProcessStarted() {
        if canStartProcess {
            startProcessIfNeeded()
        } else {
            pendingStart = true
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

    func toolSnapshot(
        index: Int,
        isSelected: Bool,
        maxHistoryCharacters: Int
    ) -> TerminalToolTabSnapshot {
        TerminalToolTabSnapshot(
            id: session?.id.uuidString ?? UUID().uuidString,
            index: index,
            title: session?.tabTitle ?? "",
            subtitle: session?.tabSubtitle,
            currentDirectory: session?.currentDirectory,
            isSelected: isSelected,
            state: session?.toolStateText ?? "unknown",
            columns: terminalView.terminal?.cols ?? 0,
            rows: terminalView.terminal?.rows ?? 0,
            screen: visibleScreenText(),
            history: String(fullHistoryText().suffix(maxHistoryCharacters)),
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
            self?.startPendingProcessIfReady()
        }
        terminalView.shouldRecordInput = { [weak self] in
            guard let session = self?.session else { return false }
            return session.isRecording && !session.isPlayingShortcut
        }
        terminalView.onSendToProcess = { [weak self] data, echoEnabled in
            self?.session?.recordInputIfNeeded(data: data, echoEnabled: echoEnabled)
        }
        container.addSubview(terminalView)
        layoutTerminalViews()
    }

    private func startProcessIfNeeded() {
        guard !didStart else { return }
        pendingStart = false
        didStart = true

        switch session?.launchConfiguration ?? .localShell {
        case .localShell:
            let shell = Self.loginShell()
            let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
            terminalView.startProcess(
                executable: shell,
                environment: Self.environmentArray(),
                execName: execName,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        case .ssh(let profile):
            do {
                let descriptor = try SSHConfigMaterializer.descriptor(for: profile)
                terminalView.startProcess(
                    executable: descriptor.executable,
                    args: descriptor.args,
                    environment: Self.environmentArray(),
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                drainStartupCommands(descriptor.startupCommands)
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

    private func startPendingProcessIfReady() {
        guard pendingStart, canStartProcess else { return }
        startProcessIfNeeded()
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

    private static func environmentArray() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["MUSETERM_TERMINAL"] = "1"
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
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
    }
}

private final class FocusableLocalProcessTerminalView: LocalProcessTerminalView {
    var onNeedsFocus: (() -> Void)?
    var onReadyForProcessStart: (() -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Void)?
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        requestFocus()
        onNeedsFocus?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        requestFocus()
        onNeedsFocus?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        requestFocus()
        onNeedsFocus?()
        super.otherMouseDown(with: event)
    }

    override func paste(_ sender: Any) {
        onNeedsFocus?()
        super.paste(sender)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if shouldRecordInput?() == true {
            let bytes = Array(data)
            let echoEnabled = cachedTerminalEchoEnabled()
            onSendToProcess?(bytes, echoEnabled)
            if echoEnabled {
                rememberExpectedEcho(bytes)
            }
        }
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if shouldRecordInput?() == true, !isExpectedEcho(slice) {
            invalidateTerminalEchoCache()
        }
        super.dataReceived(slice: slice)
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
