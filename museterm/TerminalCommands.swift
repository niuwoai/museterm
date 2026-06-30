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
