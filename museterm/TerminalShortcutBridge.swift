import AppKit
import SwiftUI

struct TerminalShortcutBridge: NSViewRepresentable {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    let isCommandPaletteActive: () -> Bool
    let onAICommandTrigger: () -> Void
    let isAICommandActive: () -> Bool
    let onAICommandDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(
            hostView: view,
            workspace: workspace,
            preferences: preferences,
            isCommandPaletteActive: isCommandPaletteActive,
            onAICommandTrigger: onAICommandTrigger,
            isAICommandActive: isAICommandActive,
            onAICommandDismiss: onAICommandDismiss
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(
            hostView: nsView,
            workspace: workspace,
            preferences: preferences,
            isCommandPaletteActive: isCommandPaletteActive,
            onAICommandTrigger: onAICommandTrigger,
            isAICommandActive: isAICommandActive,
            onAICommandDismiss: onAICommandDismiss
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private weak var hostView: NSView?
        private weak var workspace: TerminalWorkspace?
        private weak var preferences: TerminalPreferences?
        private var isCommandPaletteActive: (() -> Bool)?
        private var onAICommandTrigger: (() -> Void)?
        private var isAICommandActive: (() -> Bool)?
        private var onAICommandDismiss: (() -> Void)?
        private var doubleModifierTapDetector = DoubleModifierTapDetector()
        private var monitor: Any?

        func install(
            hostView: NSView,
            workspace: TerminalWorkspace,
            preferences: TerminalPreferences,
            isCommandPaletteActive: @escaping () -> Bool,
            onAICommandTrigger: @escaping () -> Void,
            isAICommandActive: @escaping () -> Bool,
            onAICommandDismiss: @escaping () -> Void
        ) {
            self.hostView = hostView
            self.workspace = workspace
            self.preferences = preferences
            self.isCommandPaletteActive = isCommandPaletteActive
            self.onAICommandTrigger = onAICommandTrigger
            self.isAICommandActive = isAICommandActive
            self.onAICommandDismiss = onAICommandDismiss

            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard hostView?.window?.isKeyWindow == true else { return event }

            if event.type == .flagsChanged {
                if let preferences,
                   doubleModifierTapDetector.handleFlagsChanged(
                    flags: event.modifierFlags,
                    timestamp: event.timestamp,
                    activation: preferences.aiCommandActivation
                   ) {
                    onAICommandTrigger?()
                }
                return event
            }

            doubleModifierTapDetector.registerKeyDown()

            if isCommandPaletteActive?() == true,
               let action = CommandPaletteKeyboardAction.resolve(event: event) {
                NotificationCenter.default.post(name: .commandPaletteKeyboardAction, object: action)
                return nil
            }

            if event.keyCode == 53, isAICommandActive?() == true {
                onAICommandDismiss?()
                return nil
            }

            if let preferences,
               let action = TerminalLineNavigationAction.resolve(
                   event: event,
                   lineStartShortcut: preferences.lineStartShortcut,
                   lineEndShortcut: preferences.lineEndShortcut
               ) {
                sendLineNavigation(action)
                return nil
            }

            if !event.isARepeat,
               let preferences,
               let action = TerminalAppShortcutAction.resolve(
                   event: event,
                   shortcut: { preferences.appShortcut(for: $0) }
               ) {
                perform(action, eventTimestamp: event.timestamp)
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            guard !flags.contains(.option), !flags.contains(.control) else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasShift = flags.contains(.shift)

            if !hasShift, let tabNumber = Int(key), (1...9).contains(tabNumber) {
                workspace?.selectTab(at: tabNumber - 1)
                return nil
            }

            return event
        }

        private func perform(_ action: TerminalAppShortcutAction, eventTimestamp: TimeInterval) {
            switch action {
            case .newTab:
                workspace?.newTabFromShortcut(eventTimestamp: eventTimestamp)
            case .closeTab:
                workspace?.closeSelectedTabFromShortcut(eventTimestamp: eventTimestamp)
            case .commandPalette:
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            case .searchCommands:
                NotificationCenter.default.post(name: .toggleCommandInspector, object: nil)
            case .previousTab:
                workspace?.selectPreviousTab()
            case .nextTab:
                workspace?.selectNextTab()
            }
        }

        private func sendLineNavigation(_ action: TerminalLineNavigationAction) {
            guard let workspace else { return }
            do {
                _ = try workspace.sendToolInput(to: "selected", bytes: action.bytes)
            } catch {
                NSLog("MuseTerm shortcut %@ failed: %@", String(describing: action), error.localizedDescription)
            }
        }
    }
}
