import AppKit
import SwiftUI

struct TerminalShortcutBridge: NSViewRepresentable {
    @ObservedObject var workspace: TerminalWorkspace

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(hostView: view, workspace: workspace)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(hostView: nsView, workspace: workspace)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private weak var hostView: NSView?
        private weak var workspace: TerminalWorkspace?
        private var monitor: Any?

        func install(hostView: NSView, workspace: TerminalWorkspace) {
            self.hostView = hostView
            self.workspace = workspace

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

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            guard !flags.contains(.option), !flags.contains(.control) else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasShift = flags.contains(.shift)

            if key == "t", !hasShift {
                workspace?.newTabFromShortcut(eventTimestamp: event.timestamp)
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
    }
}
