import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: TerminalPreferences
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let controller = session.controller
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
        DispatchQueue.main.async {
            session.controller.ensureProcessStarted()
            session.controller.setActive(isActive)
            if isActive {
                session.controller.focusTerminal()
                session.controller.invalidateDisplay()
            }
        }
    }
}

final class TerminalHostController: NSObject, LocalProcessTerminalViewDelegate {
    let container = NSView(frame: .zero)
    private let visualEffectView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let terminalView = FocusableLocalProcessTerminalView(frame: .zero)
    private weak var session: TerminalSession?
    private var didStart = false
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
        terminalView.frame = container.bounds
    }

    func terminate() {
        terminalView.terminate()
    }

    func ensureProcessStarted() {
        startProcessIfNeeded()
    }

    func focusTerminal() {
        terminalView.requestFocus()
    }

    func setActive(_ isActive: Bool) {
        container.alphaValue = isActive ? 1 : 0
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
        terminalView.send(source: terminalView, data: bytes[...])
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

        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        terminalView.wantsLayer = true
        terminalView.onNeedsFocus = { [weak self] in
            self?.focusTerminal()
        }
        container.addSubview(terminalView)
        layoutTerminalViews()
    }

    private func startProcessIfNeeded() {
        guard !didStart else { return }
        didStart = true

        let shell = Self.loginShell()
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        terminalView.startProcess(
            executable: shell,
            execName: execName,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.requestFocus()
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
}
