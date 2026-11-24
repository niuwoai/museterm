import AppKit
import Foundation

/// Writes a plugin command into the selected tab. Every non-empty command asks first, including
/// one the risk analyzer calls read-only. Nothing here appends a return.
enum TerminalPluginFill {
    @MainActor
    static func apply(
        _ command: String,
        plugin: TerminalPlugin,
        in workspace: TerminalWorkspace,
        selectedID: TerminalSession.ID?,
        environment: TerminalEnvironmentKind?
    ) throws {
        guard plugin.permissions.contains("terminal.fill") else {
            throw TerminalPluginError.missingPermission("terminal.fill")
        }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n"), !line.contains("\r") else {
            throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
        }
        guard confirm(plugin: plugin, command: line) else { return }
        let risk = TerminalCommandRiskAnalyzer.profile(for: line)
        if environment == .production || risk.level == .dangerous {
            guard confirm(plugin: plugin, command: line) else { return }
        }
        guard workspace.selectedTab?.id == selectedID else {
            throw TerminalPluginError.failed(L10n.string("plugin.fill.blocked"))
        }
        _ = try workspace.sendToolInput(to: "selected", bytes: Array(line.utf8))
    }

    private static func confirm(plugin: TerminalPlugin, command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string("plugin.confirm.title")
        alert.informativeText = L10n.format("plugin.confirm.message", plugin.displayName, command)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("plugin.confirm.action"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
