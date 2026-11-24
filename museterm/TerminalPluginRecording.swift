import Foundation

/// Tells enabled plugins that a recording was saved. The payload is an allowlist: a plugin cannot
/// add fields, and its return value is ignored. Failure of one plugin does not affect the save.
enum TerminalPluginRecording {
    static func notify(_ shortcut: TerminalShortcut) {
        let event = TerminalPluginRecordingEvent(
            id: shortcut.id.uuidString,
            title: shortcut.title,
            eventCount: shortcut.eventCount,
            durationMilliseconds: shortcut.durationMilliseconds,
            hasProtectedInput: shortcut.hasProtectedInput,
            requiresUserAuthentication: shortcut.requiresUserAuthentication,
            allowsAutomationPlayback: shortcut.allowsAutomationPlayback
        )
        let node = URL(fileURLWithPath: UserDefaults.standard.string(forKey: TerminalPluginSettings.nodePathKey) ?? "")
        for plugin in TerminalPluginStore.shared.enabledPlugins(with: "recording.observe") {
            guard plugin.recordingExport != nil else { continue }
            _ = try? TerminalPluginRunner.run(
                .recording(plugin: plugin, event: event),
                nodeExecutable: node
            )
        }
    }

    /// The only fields a recording callback is allowed to carry.
    static let allowedFields = [
        "id",
        "title",
        "eventCount",
        "durationMilliseconds",
        "hasProtectedInput",
        "requiresUserAuthentication",
        "allowsAutomationPlayback",
    ]
}
