import AppKit
import SwiftUI

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalWorkspace) private var workspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some Commands {
        // 覆盖 WindowGroup 默认的「新建窗口(Cmd+N)」，改为新建标签，保证单窗口运行。
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("action.new_tab")) {
                workspace?.newTabFromShortcut(eventTimestamp: NSApp.currentEvent?.timestamp)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(workspace == nil)
        }

        CommandMenu(L10n.string("menu.tab")) {
            Button(L10n.string("action.new_tab")) {
                workspace?.newTabFromShortcut(eventTimestamp: NSApp.currentEvent?.timestamp)
            }
            .terminalKeyboardShortcut(preferences.appShortcut(for: .newTab))
            .disabled(workspace == nil)

            Button(L10n.string("action.close_tab")) {
                workspace?.closeSelectedTabFromShortcut(eventTimestamp: NSApp.currentEvent?.timestamp)
            }
            .terminalKeyboardShortcut(preferences.appShortcut(for: .closeTab))
            .disabled(workspace == nil)

            Divider()

            Button(L10n.string("command_palette.title")) {
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            }
            .terminalKeyboardShortcut(preferences.appShortcut(for: .commandPalette))

            Button(L10n.string("ai_command.title")) {
                NotificationCenter.default.post(name: .showAICommandAssistant, object: nil)
            }
            .disabled(workspace == nil)

            Button(L10n.string("action.search_commands")) {
                NotificationCenter.default.post(name: .toggleCommandInspector, object: nil)
            }
            .terminalKeyboardShortcut(preferences.appShortcut(for: .searchCommands))
            .disabled(workspace == nil)

            Button(L10n.string("action.show_tasks_ports")) {
                NotificationCenter.default.post(name: .toggleTaskPortPanel, object: nil)
            }
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
            .terminalKeyboardShortcut(preferences.appShortcut(for: .previousTab))
            .disabled((workspace?.tabs.count ?? 0) < 2)

            Button(L10n.string("action.next_tab")) {
                workspace?.selectNextTab()
            }
            .terminalKeyboardShortcut(preferences.appShortcut(for: .nextTab))
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
