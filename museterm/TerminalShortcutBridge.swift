import AppKit
import SwiftUI

struct TerminalShortcutBridge: NSViewRepresentable {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(hostView: view, workspace: workspace, preferences: preferences)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(hostView: nsView, workspace: workspace, preferences: preferences)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private weak var hostView: NSView?
        private weak var workspace: TerminalWorkspace?
        private weak var preferences: TerminalPreferences?
        private var monitor: Any?

        func install(hostView: NSView, workspace: TerminalWorkspace, preferences: TerminalPreferences) {
            self.hostView = hostView
            self.workspace = workspace
            self.preferences = preferences

            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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

            if let preferences,
               let action = TerminalLineNavigationAction.resolve(
                   event: event,
                   lineStartShortcut: preferences.lineStartShortcut,
                   lineEndShortcut: preferences.lineEndShortcut
               ) {
                sendLineNavigation(action)
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            guard !flags.contains(.option), !flags.contains(.control) else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasShift = flags.contains(.shift)

            if key == "t", !hasShift {
                workspace?.newTabFromShortcut(eventTimestamp: event.timestamp)
                return nil
            }

            if key == "w", !hasShift {
                workspace?.closeSelectedTabFromShortcut(eventTimestamp: event.timestamp)
                return nil
            }

            if key == "[", hasShift {
                workspace?.selectPreviousTab()
                return nil
            }

            if key == "]", hasShift {
                workspace?.selectNextTab()
                return nil
            }

            if !hasShift, let tabNumber = Int(key), (1...9).contains(tabNumber) {
                workspace?.selectTab(at: tabNumber - 1)
                return nil
            }

            return event
        }

        private func sendLineNavigation(_ action: TerminalLineNavigationAction) {
            guard let workspace else { return }
            do {
                _ = try workspace.sendToolInput(to: "selected", bytes: action.bytes)
            } catch {
                NSLog("QTerm shortcut %@ failed: %@", String(describing: action), error.localizedDescription)
            }
        }
    }
}
