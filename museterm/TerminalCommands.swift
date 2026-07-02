import AppKit
import SwiftUI

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalWorkspace) private var workspace

    var body: some Commands {
        CommandMenu(L10n.string("menu.tab")) {
            Button(L10n.string("action.new_tab")) {
                workspace?.newTabFromShortcut(eventTimestamp: NSApp.currentEvent?.timestamp)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace == nil)

            Button(L10n.string("action.close_tab")) {
                workspace?.closeSelectedTabFromShortcut(eventTimestamp: NSApp.currentEvent?.timestamp)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(workspace == nil)

            Divider()

            Button(L10n.string("action.search_commands")) {
                NotificationCenter.default.post(name: .toggleCommandInspector, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(workspace == nil)

            Button(L10n.string("action.show_tasks_ports")) {
                NotificationCenter.default.post(name: .toggleTaskPortPanel, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(workspace == nil)

            Divider()

            Button(L10n.string("action.save_workspace")) {
                guard let workspace else { return }
                saveWorkspace(workspace)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(workspace == nil)

            Button(L10n.string("action.restore_workspace")) {
                guard let workspace else { return }
                restoreWorkspace(workspace)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(workspace == nil)

            Divider()

            Button(L10n.string("action.previous_tab")) {
                workspace?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((workspace?.tabs.count ?? 0) < 2)

            Button(L10n.string("action.next_tab")) {
                workspace?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((workspace?.tabs.count ?? 0) < 2)

            Divider()

            ForEach(1...9, id: \.self) { tabNumber in
                Button(L10n.format("action.select_tab", tabNumber)) {
                    workspace?.selectTab(at: tabNumber - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(tabNumber))), modifiers: .command)
                .disabled((workspace?.tabs.count ?? 0) < tabNumber)
            }
        }
    }

    private func saveWorkspace(_ workspace: TerminalWorkspace) {
        do {
            try workspace.saveSnapshot()
            showAlert(
                title: L10n.string("workspace.alert.title"),
                message: L10n.string("workspace.saved"),
                style: .informational
            )
        } catch {
            showAlert(
                title: L10n.string("workspace.save_failed"),
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func restoreWorkspace(_ workspace: TerminalWorkspace) {
        guard confirmWorkspaceRestore() else { return }

        do {
            try workspace.restoreSnapshot()
            showAlert(
                title: L10n.string("workspace.alert.title"),
                message: L10n.string("workspace.restored"),
                style: .informational
            )
        } catch {
            showAlert(
                title: L10n.string("workspace.restore_failed"),
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func confirmWorkspaceRestore() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string("workspace.restore_confirm.title")
        alert.informativeText = L10n.string("workspace.restore_confirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("workspace.restore_confirm.action"))
        alert.addButton(withTitle: L10n.string("workspace.restore_confirm.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: L10n.string("action.ok"))
        alert.runModal()
    }
}

private struct TerminalWorkspaceFocusedKey: FocusedValueKey {
    typealias Value = TerminalWorkspace
}

extension FocusedValues {
    var terminalWorkspace: TerminalWorkspace? {
        get { self[TerminalWorkspaceFocusedKey.self] }
        set { self[TerminalWorkspaceFocusedKey.self] = newValue }
    }
}
