import AppKit
import SwiftUI

enum AboutWindowOpener {
    private static var windowController: NSWindowController?

    static func open(preferences: TerminalPreferences) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let hostingController = NSHostingController(rootView: AboutView(preferences: preferences))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.string("about.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        activateApp()
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
