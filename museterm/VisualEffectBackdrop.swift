import AppKit
import SwiftUI

struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

enum TerminalWindowCloseState {
    static var isAppTerminating = false
}

final class TerminalWindowCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var workspace: TerminalWorkspace?
    private weak var configuredWindow: NSWindow?

    func bind(workspace: TerminalWorkspace) {
        self.workspace = workspace
    }

    func configure(window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        if configuredWindow !== window {
            if configuredWindow?.delegate === self {
                configuredWindow?.delegate = nil
            }
            configuredWindow = window
        }
        if window.delegate !== self {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        handleWindowCloseRequest()
    }

    @discardableResult
    func handleWindowCloseRequest() -> Bool {
        guard !TerminalWindowCloseState.isAppTerminating else { return true }
        guard let workspace else { return true }

        _ = workspace.closeSelectedTab()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === configuredWindow else { return }
        if window.delegate === self {
            window.delegate = nil
        }
        configuredWindow = nil
    }

    deinit {
        if configuredWindow?.delegate === self {
            configuredWindow?.delegate = nil
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    @ObservedObject var workspace: TerminalWorkspace

    func makeCoordinator() -> TerminalWindowCloseCoordinator {
        let coordinator = TerminalWindowCloseCoordinator()
        coordinator.bind(workspace: workspace)
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.bind(workspace: workspace)
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.bind(workspace: workspace)
        DispatchQueue.main.async {
            context.coordinator.configure(window: nsView.window)
        }
    }
}
