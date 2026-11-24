import Foundation

/// Asks enabled plugins for extra command candidates. A timeout or a bad reply drops that plugin
/// and leaves the built-in candidates alone.
enum TerminalPluginSuggestions {
    static let maximumPlugins = 4

    static func collect(request: String, context: AICommandContext) -> [AICommandSuggestion] {
        let node = URL(fileURLWithPath: UserDefaults.standard.string(forKey: TerminalPluginSettings.nodePathKey) ?? "")
        let plugins = Array(TerminalPluginStore.shared.enabledPlugins(with: "ai.suggest").prefix(maximumPlugins))
        let tab = TerminalPluginTabContext(
            id: context.tabID.uuidString,
            targetKind: context.targetKind.rawValue,
            environment: context.environment.rawValue,
            targetName: context.targetName,
            user: context.user,
            host: context.host,
            workingDirectory: context.workingDirectory,
            shell: context.shell
        )
        return plugins.flatMap { plugin -> [AICommandSuggestion] in
            guard let export = plugin.suggestExport else { return [] }
            let result = try? TerminalPluginRunner.run(
                .suggest(plugin: plugin, request: request, context: tab),
                nodeExecutable: node
            )
            guard case let .suggestions(pairs) = result else { return [] }
            return pairs.map { pair in
                AICommandSuggestion(
                    command: pair.command,
                    explanation: pair.explanation.isEmpty
                        ? L10n.string("ai_command.explanation_fallback")
                        : pair.explanation,
                    pluginID: plugin.id,
                    pluginName: plugin.displayName
                )
            }
        }
    }
}
