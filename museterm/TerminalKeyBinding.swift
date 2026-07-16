import AppKit
import SwiftUI

struct TerminalKeyBinding: Equatable {
    static let defaultLineStart = TerminalKeyBinding(storageValue: "command+left")!
    static let defaultLineEnd = TerminalKeyBinding(storageValue: "command+right")!

    private static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let modifierTokens: [(flag: NSEvent.ModifierFlags, token: String, symbol: String)] = [
        (.control, "control", "⌃"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘")
    ]

    let modifiers: NSEvent.ModifierFlags
    let key: String

    init?(storageValue: String) {
        let tokens = storageValue
            .split(separator: "+")
            .map { String($0).lowercased() }
        guard let key = tokens.last, Self.isSupportedKey(key) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            guard let modifier = Self.modifierTokens.first(where: { $0.token == token }) else { return nil }
            modifiers.insert(modifier.flag)
        }
        guard Self.isSafeShortcut(key: key, modifiers: modifiers) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard let key = Self.keyIdentifier(for: event), Self.isSafeShortcut(key: key, modifiers: modifiers) else {
            return nil
        }
        self.modifiers = modifiers
        self.key = key
    }

    var storageValue: String {
        let modifierValues = Self.modifierTokens.compactMap { modifiers.contains($0.flag) ? $0.token : nil }
        return (modifierValues + [key]).joined(separator: "+")
    }

    var displayName: String {
        let modifierSymbols = Self.modifierTokens
            .filter { modifiers.contains($0.flag) }
            .map(\.symbol)
            .joined()
        return modifierSymbols + Self.keyDisplayName(key)
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "plus": return KeyEquivalent("+")
        default:
            guard key.hasPrefix("char:"), let character = key.dropFirst(5).first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }

    var isReservedApplicationShortcut: Bool {
        Self.reservedApplicationShortcuts.contains(storageValue)
    }

    func matches(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(Self.supportedModifiers) == modifiers
            && Self.keyIdentifier(for: event) == key
    }

    private static func keyIdentifier(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 115: return "home"
        case 119: return "end"
        case 116: return "pageup"
        case 121: return "pagedown"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
                  let scalar = characters.unicodeScalars.first, scalar.value < 0xF700 else {
                return nil
            }
            if characters == "+" { return "plus" }
            return "char:\(characters)"
        }
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        switch key {
        case "left", "right", "up", "down", "home", "end", "pageup", "pagedown", "plus":
            return true
        default:
            return key.hasPrefix("char:") && key.dropFirst(5).count == 1
        }
    }

    private static func isSafeShortcut(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        if key == "home" || key == "end" {
            return true
        }
        return !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    private static func keyDisplayName(_ key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "Page Up"
        case "pagedown": return "Page Down"
        case "plus": return "+"
        default:
            return String(key.dropFirst(5)).uppercased()
        }
    }

    private static let reservedApplicationShortcuts: Set<String> = {
        var values: Set<String> = [
            "command+char:q",
            "command+char:h",
            "option+command+char:h",
            "command+char:m",
            "command+char:,",
            "command+char:n",
            "option+command+char:s",
            "option+command+char:o",
            "command+char:c",
            "command+char:v",
            "command+char:x",
            "command+char:a",
            "command+char:z",
            "shift+command+char:z"
        ]
        for tabNumber in 1...9 {
            values.insert("command+char:\(tabNumber)")
        }
        return values
    }()
}

enum TerminalAppShortcutAction: String, CaseIterable, Identifiable {
    case newTab
    case closeTab
    case commandPalette
    case searchCommands
    case previousTab
    case nextTab

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .newTab: return "action.new_tab"
        case .closeTab: return "action.close_tab"
        case .commandPalette: return "command_palette.title"
        case .searchCommands: return "action.search_commands"
        case .previousTab: return "action.previous_tab"
        case .nextTab: return "action.next_tab"
        }
    }

    var defaultStorageValue: String {
        switch self {
        case .newTab: return "command+char:t"
        case .closeTab: return "command+char:w"
        case .commandPalette: return "shift+command+char:p"
        case .searchCommands: return "command+char:f"
        case .previousTab: return "shift+command+char:["
        case .nextTab: return "shift+command+char:]"
        }
    }

    static func resolve(
        event: NSEvent,
        shortcut: (TerminalAppShortcutAction) -> String
    ) -> TerminalAppShortcutAction? {
        allCases.first { action in
            TerminalKeyBinding(storageValue: shortcut(action))?.matches(event) == true
        }
    }
}

private struct OptionalTerminalKeyboardShortcutModifier: ViewModifier {
    let storageValue: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding = TerminalKeyBinding(storageValue: storageValue),
           let keyEquivalent = binding.keyEquivalent {
            content.keyboardShortcut(keyEquivalent, modifiers: binding.eventModifiers)
        } else {
            content
        }
    }
}

extension View {
    func terminalKeyboardShortcut(_ storageValue: String) -> some View {
        modifier(OptionalTerminalKeyboardShortcutModifier(storageValue: storageValue))
    }
}

enum TerminalLineNavigationAction: Equatable {
    case lineStart
    case lineEnd

    var bytes: [UInt8] {
        switch self {
        case .lineStart: return [0x01]
        case .lineEnd: return [0x05]
        }
    }

    static func resolve(
        event: NSEvent,
        lineStartShortcut: String,
        lineEndShortcut: String
    ) -> TerminalLineNavigationAction? {
        if TerminalKeyBinding(storageValue: lineStartShortcut)?.matches(event) == true {
            return .lineStart
        }
        if TerminalKeyBinding(storageValue: lineEndShortcut)?.matches(event) == true {
            return .lineEnd
        }
        return nil
    }
}

struct TerminalKeyShortcutRecorder: NSViewRepresentable {
    @Binding var storageValue: String
    let validator: (TerminalKeyBinding) -> Bool

    init(
        storageValue: Binding<String>,
        validator: @escaping (TerminalKeyBinding) -> Bool = { !$0.isReservedApplicationShortcut }
    ) {
        _storageValue = storageValue
        self.validator = validator
    }

    func makeNSView(context: Context) -> TerminalKeyShortcutRecorderButton {
        let button = TerminalKeyShortcutRecorderButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: TerminalKeyShortcutRecorderButton, context: Context) {
        configure(button)
    }

    private func configure(_ button: TerminalKeyShortcutRecorderButton) {
        button.binding = TerminalKeyBinding(storageValue: storageValue)
        button.validator = validator
        button.onChange = { binding in
            storageValue = binding?.storageValue ?? ""
        }
        button.toolTip = L10n.string("settings.shortcuts.record_help")
        button.setAccessibilityLabel(L10n.string("settings.shortcuts.record_accessibility"))
    }
}

final class TerminalKeyShortcutRecorderButton: NSButton {
    var binding: TerminalKeyBinding? {
        didSet { refreshTitle() }
    }
    var onChange: ((TerminalKeyBinding?) -> Void)?
    var validator: (TerminalKeyBinding) -> Bool = { _ in true }

    private var isRecordingShortcut = false
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .rounded
        alignment = .center
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeEventMonitor()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecordingShortcut {
            finishRecording()
        }
        return resigned
    }

    @objc private func beginRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        title = L10n.string("settings.shortcuts.recording")
        window?.makeFirstResponder(self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecordingShortcut else { return event }
            self.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            finishRecording()
        case 51, 117:
            binding = nil
            onChange?(nil)
            finishRecording()
        default:
            guard let captured = TerminalKeyBinding(event: event) else {
                NSSound.beep()
                return
            }
            guard validator(captured) else {
                NSSound.beep()
                return
            }
            binding = captured
            onChange?(captured)
            finishRecording()
        }
    }

    private func finishRecording() {
        isRecordingShortcut = false
        removeEventMonitor()
        refreshTitle()
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private func refreshTitle() {
        guard !isRecordingShortcut else { return }
        title = binding?.displayName ?? L10n.string("settings.shortcuts.unassigned")
    }
}
