import AppKit
import SwiftUI

enum SettingsWindowOpener {
    private static var windowController: NSWindowController?

    static func open(preferences: TerminalPreferences) {
        if let window = windowController?.window {
            window.setContentSize(SettingsView.defaultWindowSize)
            centerAndClearFocus(window)
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(preferences: preferences, profileStore: .shared)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.string("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil
        window.setContentSize(SettingsView.defaultWindowSize)

        let controller = NSWindowController(window: window)
        windowController = controller
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
