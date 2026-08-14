import AppKit
import SwiftUI

enum SettingsWindowOpener {
    private static var windowController: NSWindowController?
    private static var session: SettingsWindowSession?

    static func open(preferences: TerminalPreferences) {
        if let window = windowController?.window {
            window.setContentSize(SettingsView.defaultWindowSize)
            centerAndClearFocus(window)
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let settingsSession = SettingsWindowSession()
        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                profileStore: .shared,
                session: settingsSession
            )
        )
        let window = SettingsWindow(contentViewController: hostingController)
        window.title = L10n.string("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil
        window.setContentSize(SettingsView.defaultWindowSize)

        let controller = NSWindowController(window: window)
        session = settingsSession
        windowController = controller
        window.onEscape = { [weak window] in
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                guard settingsSession.savePendingAIAPIKey(preferences: preferences) else {
                    NSSound.beep()
                    return
                }
                window?.close()
            }
        }
        controller.showWindow(nil)
        centerAndClearFocus(window)
        activateApp()
    }

    private static func centerAndClearFocus(_ window: NSWindow) {
        window.center()
        window.makeFirstResponder(nil)
        DispatchQueue.main.async {
            window.center()
            window.makeFirstResponder(nil)
        }
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class SettingsWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown,
           event.keyCode == 53,
           modifiers.isEmpty,
           attachedSheet == nil,
           let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}
