import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var workspace = TerminalWorkspace()
    @StateObject private var sshStore = SSHConnectionStore()
    @ObservedObject private var preferences: TerminalPreferences
    @State private var rightPanel: TerminalRightPanel?

    init(preferences: TerminalPreferences = TerminalPreferences()) {
        self.preferences = preferences
    }

    var body: some View {
        ZStack {
            preferences.skin.windowBackground
                .ignoresSafeArea()
            if preferences.glassEnabled {
                VisualEffectBackdrop(
                    material: preferences.glassMaterial.nsMaterial,
                    blendingMode: .behindWindow,
                    state: .active
                )
                .opacity(preferences.glassOpacity)
                .ignoresSafeArea()
            }

            HStack(spacing: 0) {
                SidebarView(
                    workspace: workspace,
                    sshStore: sshStore,
                    preferences: preferences
                )

                TerminalPaneView(workspace: workspace, preferences: preferences)
                    .ignoresSafeArea(.container, edges: .top)

                if rightPanel == .commandInspector {
                    CommandInspectorView(
                        workspace: workspace,
                        preferences: preferences,
                        isVisible: rightPanelBinding(.commandInspector)
                    )
                } else if rightPanel == .tasks {
                    TaskPortPanelView(
                        workspace: workspace,
                        preferences: preferences,
                        isVisible: rightPanelBinding(.tasks)
                    )
                }
            }
        }
        .background(WindowConfigurator())
        .background(TerminalShortcutBridge(workspace: workspace))
        .focusedValue(\.terminalWorkspace, workspace)
        .tint(preferences.skin.accent)
        .preferredColorScheme(preferences.skin.preferredColorScheme)
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            TerminalToolBridge.shared.attach(workspace: workspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandInspector)) { _ in
            toggleRightPanel(.commandInspector)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTaskPortPanel)) { _ in
            toggleRightPanel(.tasks)
        }
    }

    private func toggleRightPanel(_ panel: TerminalRightPanel) {
        rightPanel = rightPanel == panel ? nil : panel
    }

    private func rightPanelBinding(_ panel: TerminalRightPanel) -> Binding<Bool> {
        Binding(
            get: { rightPanel == panel },
            set: { isVisible in
                rightPanel = isVisible ? panel : nil
            }
        )
    }
}

private enum TerminalRightPanel {
    case commandInspector
    case tasks
}

private struct SidebarView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var sshStore: SSHConnectionStore
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        VStack(spacing: 0) {
            header
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if preferences.showsTabList {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        VStack(spacing: 4) {
                            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                                TabRowView(
                                    tab: tab,
                                    isSelected: workspace.selectedID == tab.id,
                                    shortcutNumber: index < 9 ? index + 1 : nil,
                                    skin: preferences.skin,
                                    closeAction: { workspace.close(tab) }
                                )
                                .onTapGesture {
                                    workspace.select(tab)
                                }
                            }
                        }

                        TerminalShortcutSection(workspace: workspace, skin: preferences.skin)

                        FileTransferSection(workspace: workspace, skin: preferences.skin)

                        SSHProfilesSection(
                            workspace: workspace,
                            store: sshStore,
                            skin: preferences.skin
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 8)

            HStack {
                if preferences.showsTabList {
                    Spacer()
                }
                Button {
                    SettingsWindowOpener.open(preferences: preferences)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L10n.string("action.settings"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: preferences.showsTabList ? 220 : 56)
        .background(preferences.skin.sidebarBackground)
    }

    @ViewBuilder
    private var header: some View {
        if preferences.showsTabList {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(preferences.skin.accent)
                Text(L10n.string("app.name"))
                    .font(.headline)
                Spacer()
                IconButton(systemName: "plus", title: L10n.string("action.new_tab")) {
                    workspace.newTab()
                }
                IconButton(
                    systemName: "magnifyingglass",
                    title: L10n.string("command_inspector.title")
                ) {
                    NotificationCenter.default.post(name: .toggleCommandInspector, object: nil)
                }
                IconButton(
                    systemName: "server.rack",
                    title: L10n.string("task_panel.title")
                ) {
                    NotificationCenter.default.post(name: .toggleTaskPortPanel, object: nil)
                }
                IconButton(
                    systemName: "sidebar.left",
                    title: L10n.string("action.hide_tab_list")
                ) {
                    preferences.showsTabList = false
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(preferences.skin.accent)
                    .frame(width: 28, height: 28)
                IconButton(systemName: "sidebar.right", title: L10n.string("action.show_tab_list")) {
                    preferences.showsTabList = true
                }
                IconButton(systemName: "plus", title: L10n.string("action.new_tab")) {
                    workspace.newTab()
                }
            }
        }
    }
}

extension Notification.Name {
    static let toggleCommandInspector = Notification.Name("MuseTermToggleCommandInspector")
    static let toggleTaskPortPanel = Notification.Name("MuseTermToggleTaskPortPanel")
}

private struct TabRowView: View {
    @ObservedObject var tab: TerminalSession
    let isSelected: Bool
    let shortcutNumber: Int?
    let skin: TerminalVisualSkin
    let closeAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(tab.tabTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let shortcutNumber {
                        // 稍浅颜色备注 ⌘ 数字，提示 Command+N 可直接切到该标签。
                        Text(verbatim: "⌘\(shortcutNumber)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let subtitle = tab.tabSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if tab.environment != .local {
                EnvironmentBadge(environment: tab.environment)
            }

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .disabled(!isHovering)
            .accessibilityHidden(!isHovering)
            .help(L10n.string("action.close_tab"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(isSelected ? skin.selectionFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.hairline : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var statusColor: Color {
        switch tab.state {
        case .running: return skin.accent
        case .exited: return .secondary.opacity(0.55)
        }
    }
}

private struct TerminalPaneView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        ZStack {
            preferences.skin.panelFill
            ForEach(workspace.tabs) { tab in
                let isSelected = workspace.selectedID == tab.id
                TerminalHostView(session: tab, preferences: preferences, isActive: isSelected)
                    .id(tab.id)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
        }
    }
}

private struct CommandInspectorView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    @Binding var isVisible: Bool
    @State private var query = ""
    @State private var failuresOnly = false
    @State private var redactSensitiveData = true
    @State private var includeReplayScript = true
    @State private var parameterizeReplayScript = true
    @State private var confirmReplaySteps = true
    @State private var runbookHomePath = ""
    @State private var runbookWorkingDirectory = ""
    @State private var runbookNote = ""
    @State private var copiedMessage = ""
    @State private var explainingBlockID: UUID?
    @State private var explainedCommand = ""
    @State private var aiExplanation = ""
    @State private var aiExplainError = ""
    @State private var aiContextScope: AIExplainContextScope = .currentBlock

    private var blocks: [TerminalCommandBlock] {
        guard let tab = workspace.selectedTab else { return [] }
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.commandBlocks
            .reversed()
            .filter { block in
                if failuresOnly, block.exitCode == nil || block.exitCode == 0 {
                    return false
                }
                guard !cleaned.isEmpty else { return true }
                return block.searchableText.localizedCaseInsensitiveContains(cleaned)
            }
    }

    private var sensitiveOutputBlocks: [TerminalCommandBlock] {
        blocks.filter { RunbookSensitiveRedactor.containsSensitiveData($0.outputTail) }
    }

    private var historySearchResult: TerminalHistorySearchResult? {
        guard let tab = workspace.selectedTab, !failuresOnly else { return nil }
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return TerminalHistorySearchResult(
            query: cleaned,
            history: tab.historySearchSnapshot,
            redactSensitiveData: redactSensitiveData
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.45)
            controls
            Divider()
                .opacity(0.45)
            content
        }
        .frame(width: 340)
        .background(preferences.skin.sidebarBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(preferences.skin.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("command_inspector.title"))
                    .font(.headline)
                Text(workspace.selectedTab?.tabTitle ?? L10n.string("command_inspector.no_tab"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.string("action.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.string("command_inspector.search_placeholder"), text: $query)
                .textFieldStyle(.roundedBorder)
            Toggle(L10n.string("command_inspector.failures_only"), isOn: $failuresOnly)
                .font(.caption)
            Toggle(L10n.string("runbook.redact_sensitive"), isOn: $redactSensitiveData)
                .font(.caption)
            Toggle(L10n.string("runbook.include_replay_script"), isOn: $includeReplayScript)
                .font(.caption)
            if includeReplayScript {
                Toggle(L10n.string("runbook.parameterize_paths"), isOn: $parameterizeReplayScript)
                    .font(.caption)
                Toggle(L10n.string("runbook.confirm_each_step"), isOn: $confirmReplaySteps)
                    .font(.caption)
                if parameterizeReplayScript {
                    runbookVariableEditor
                }
            }
            Picker(L10n.string("ai_explain.context_scope"), selection: $aiContextScope) {
                ForEach(AIExplainContextScope.allCases) { scope in
                    Text(scope.name)
                        .tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
            TextField(L10n.string("runbook.note_placeholder"), text: $runbookNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(2...4)
            HStack(spacing: 8) {
                Button {
                    exportRunbookToClipboard()
                } label: {
                    Label(L10n.string("runbook.copy"), systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(preferences.skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(runbookExportBlocks.isEmpty)

                Button {
                    saveRunbook()
                } label: {
                    Label(L10n.string("runbook.save"), systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(preferences.skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(runbookExportBlocks.isEmpty)

                Button {
                    copyReplayScript()
                } label: {
                    Label(L10n.string("runbook.copy_replay"), systemImage: "play.rectangle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(preferences.skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(runbookExportBlocks.isEmpty)
            }
            if !copiedMessage.isEmpty {
                Text(copiedMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            sensitiveOutputPanel
            aiExplainPanel
        }
        .padding(12)
    }

    @ViewBuilder
    private var sensitiveOutputPanel: some View {
        if !sensitiveOutputBlocks.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text(
                    L10n.format(
                        redactSensitiveData
                            ? "safety.sensitive_output.redacted"
                            : "safety.sensitive_output.visible",
                        sensitiveOutputBlocks.count
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(preferences.skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(preferences.skin.hairline, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var aiExplainPanel: some View {
        if explainingBlockID != nil || !aiExplanation.isEmpty || !aiExplainError.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(L10n.string("ai_explain.title"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if explainingBlockID != nil {
                        ProgressView()
                            .scaleEffect(0.55)
                    } else {
                        Button {
                            clearAIExplanation()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("action.close"))
                    }
                }
                .foregroundStyle(preferences.skin.accent)

                if !explainedCommand.isEmpty {
                    Text(explainedCommand)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if !aiExplainError.isEmpty {
                    Text(aiExplainError)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if !aiExplanation.isEmpty {
                    ScrollView {
                        Text(aiExplanation)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    if explainingBlockID != nil {
                        Text(L10n.string("ai_explain.streaming"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.string("ai_explain.loading"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(preferences.skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(preferences.skin.hairline, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if workspace.selectedTab == nil {
            emptyState(L10n.string("command_inspector.no_tab"))
        } else if blocks.isEmpty, historySearchResult == nil {
            emptyState(L10n.string("command_inspector.empty"))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let historySearchResult {
                        HistorySearchResultCard(
                            result: historySearchResult,
                            skin: preferences.skin,
                            copySnippet: {
                                copy(
                                    historySearchResult.snippet,
                                    messageKey: "command_inspector.copied_history"
                                )
                            }
                        )
                    }
                    ForEach(blocks) { block in
                        CommandBlockCard(
                            block: block,
                            skin: preferences.skin,
                            displayOutput: outputText(for: block),
                            displaySummary: outputSummaryText(for: block),
                            diagnosticLine: outputDiagnosticLine(for: block),
                            hasSensitiveOutput: RunbookSensitiveRedactor.containsSensitiveData(block.outputTail),
                            copyCommand: { copy(block.command, messageKey: "command_inspector.copied_command") },
                            copyOutput: {
                                copy(
                                    outputText(for: block),
                                    messageKey: redactSensitiveData && RunbookSensitiveRedactor.containsSensitiveData(block.outputTail)
                                        ? "command_inspector.copied_redacted_output"
                                        : "command_inspector.copied_output"
                                )
                            },
                            copyAIContext: { copy(aiContext(for: block), messageKey: "command_inspector.copied_ai_context") },
                            copyOutputSummary: {
                                copy(
                                    outputSummaryText(for: block),
                                    messageKey: "command_inspector.copied_output_summary"
                                )
                            },
                            stageCommand: { stageCommand(block.command) },
                            explainCommand: { Task { await explain(block) } },
                            isExplaining: explainingBlockID == block.id
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func copy(_ text: String, messageKey: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = L10n.string(messageKey)
    }

    private var runbookExportBlocks: [TerminalCommandBlock] {
        blocks.reversed()
    }

    private var runbookVariableEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("runbook.variables"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.string("runbook.home_path"), text: $runbookHomePath)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField(L10n.string("runbook.workdir_path"), text: $runbookWorkingDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Text(
                L10n.format(
                    "runbook.variable_defaults",
                    effectiveRunbookVariables.homePath,
                    effectiveRunbookVariables.workingDirectory ?? L10n.string("runbook.no_workdir")
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Button {
                runbookHomePath = ""
                runbookWorkingDirectory = ""
            } label: {
                Label(L10n.string("runbook.reset_variables"), systemImage: "arrow.counterclockwise")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(preferences.skin.controlFill.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var runbookVariableOverrides: RunbookReplayVariableOverrides {
        RunbookReplayVariableOverrides(
            homePath: runbookHomePath,
            workingDirectory: runbookWorkingDirectory
        )
    }

    private var effectiveRunbookVariables: RunbookReplayVariables {
        RunbookReplayVariables(blocks: runbookExportBlocks, overrides: runbookVariableOverrides)
    }

    private func exportRunbookToClipboard() {
        guard let tab = workspace.selectedTab else { return }
        let markdown = RunbookMarkdownExporter.markdown(
            tab: tab,
            blocks: runbookExportBlocks,
            query: query,
            failuresOnly: failuresOnly,
            note: runbookNote,
            redactSensitiveData: redactSensitiveData,
            includeReplayScript: includeReplayScript,
            parameterizeReplayScript: parameterizeReplayScript,
            confirmReplaySteps: confirmReplaySteps,
            variableOverrides: runbookVariableOverrides
        )
        copy(markdown, messageKey: "runbook.copied")
    }

    private func saveRunbook() {
        guard let tab = workspace.selectedTab else { return }
        let markdown = RunbookMarkdownExporter.markdown(
            tab: tab,
            blocks: runbookExportBlocks,
            query: query,
            failuresOnly: failuresOnly,
            note: runbookNote,
            redactSensitiveData: redactSensitiveData,
            includeReplayScript: includeReplayScript,
            parameterizeReplayScript: parameterizeReplayScript,
            confirmReplaySteps: confirmReplaySteps,
            variableOverrides: runbookVariableOverrides
        )
        guard !markdown.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = L10n.string("runbook.save_title")
        panel.prompt = L10n.string("runbook.save")
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.nameFieldStringValue = RunbookMarkdownExporter.defaultFilename(for: tab)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            copiedMessage = L10n.string("runbook.saved")
        } catch {
            copiedMessage = L10n.format("runbook.save_failed", error.localizedDescription)
        }
    }

    private func aiContext(for block: TerminalCommandBlock) -> String {
        [
            "Provider: \(preferences.aiDisplayProviderName)",
            "Model: \(preferences.aiModel)",
            "Base URL: \(preferences.aiBaseURL)",
            "",
            commandContext(for: block)
        ].joined(separator: "\n")
    }

    private func commandContext(for block: TerminalCommandBlock) -> String {
        let context: String
        switch aiContextScope {
        case .commandOnly:
            context = block.aiContextText(includeOutput: false)
        case .currentBlock:
            context = block.aiContextText(includeOutput: true)
        case .currentFilter:
            context = filteredContext(focusedBlock: block)
        }
        return redactSensitiveData ? RunbookSensitiveRedactor.redact(context) : context
    }

    private func filteredContext(focusedBlock: TerminalCommandBlock) -> String {
        var lines: [String] = []
        lines.append("Focused command block:")
        lines.append(focusedBlock.aiContextText(includeOutput: true))

        if let diagnostics = CommandBlockDiagnostics(
            blocks: runbookExportBlocks,
            redactSensitiveData: false
        ).aiContextText {
            lines.append("")
            lines.append(diagnostics)
        }

        let relatedBlocks = runbookExportBlocks
            .filter { $0.id != focusedBlock.id }
            .suffix(6)
        if !relatedBlocks.isEmpty {
            lines.append("")
            lines.append("Related filtered command blocks:")
            for block in relatedBlocks {
                lines.append("")
                lines.append("- Command: \(block.command)")
                if let workingDirectory = block.workingDirectory {
                    lines.append("  Directory: \(workingDirectory)")
                }
                lines.append("  Status: \(block.statusText)")
                if let durationMilliseconds = block.durationMilliseconds {
                    lines.append("  Duration: \(durationMilliseconds) ms")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func outputText(for block: TerminalCommandBlock) -> String {
        redactSensitiveData ? RunbookSensitiveRedactor.redact(block.outputTail) : block.outputTail
    }

    private func outputSummaryText(for block: TerminalCommandBlock) -> String {
        if let outputSummary = block.outputSummary, !outputSummary.isEmpty {
            return redactSensitiveData
                ? RunbookSensitiveRedactor.redact(outputSummary.aiContextText)
                : outputSummary.aiContextText
        }
        return TerminalOutputInsightAnalyzer.summary(in: outputText(for: block))
    }

    private func outputDiagnosticLine(for block: TerminalCommandBlock) -> String? {
        guard let diagnosticLine = block.outputSummary?.primaryDiagnosticLine else { return nil }
        let result = redactSensitiveData ? RunbookSensitiveRedactor.redact(diagnosticLine) : diagnosticLine
        return result.isEmpty ? nil : result
    }

    private func copyReplayScript() {
        let script = RunbookMarkdownExporter.replayScript(
            blocks: runbookExportBlocks,
            redactSensitiveData: redactSensitiveData,
            parameterizePaths: parameterizeReplayScript,
            confirmEachStep: confirmReplaySteps,
            variableOverrides: runbookVariableOverrides
        )
        copy(script, messageKey: "runbook.replay_copied")
    }

    private func stageCommand(_ command: String) {
        guard let tab = workspace.selectedTab else { return }
        tab.controller.sendProcessInput(bytes: Array(command.utf8))
        copiedMessage = L10n.string("runbook.command_staged")
    }

    @MainActor
    private func explain(_ block: TerminalCommandBlock) async {
        guard explainingBlockID == nil else { return }
        clearAIExplanation()
        explainingBlockID = block.id
        explainedCommand = block.command
        defer { explainingBlockID = nil }

        do {
            let configuration = try AIExplainClient.Configuration(preferences: preferences)
            let text = try await AIExplainClient(configuration: configuration).explain(
                contextText: commandContext(for: block)
            ) { chunk in
                aiExplanation += chunk
            }
            if aiExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiExplanation = text
            }
        } catch {
            aiExplainError = error.localizedDescription
        }
    }

    private func clearAIExplanation() {
        explainedCommand = ""
        aiExplanation = ""
        aiExplainError = ""
    }
}

private struct TerminalHistorySearchResult: Equatable {
    let query: String
    let snippet: String
    let matchCount: Int

    init?(query: String, history: String, redactSensitiveData: Bool) {
        let source = redactSensitiveData ? RunbookSensitiveRedactor.redact(history) : history
        guard let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        self.query = query
        snippet = Self.snippet(around: range, in: source)
        matchCount = Self.matchCount(of: query, in: source)
    }

    private static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let leadingCharacters = 900
        let trailingCharacters = 1_200
        let lowerBound = text.index(
            range.lowerBound,
            offsetBy: -min(leadingCharacters, text.distance(from: text.startIndex, to: range.lowerBound)),
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upperDistance = text.distance(from: range.upperBound, to: text.endIndex)
        let upperBound = text.index(
            range.upperBound,
            offsetBy: min(trailingCharacters, upperDistance),
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let prefix = lowerBound == text.startIndex ? "" : "...\n"
        let suffix = upperBound == text.endIndex ? "" : "\n..."
        return prefix + String(text[lowerBound..<upperBound]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private static func matchCount(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let range = text[searchStart...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

private struct HistorySearchResultCard: View {
    let result: TerminalHistorySearchResult
    let skin: TerminalVisualSkin
    let copySnippet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(L10n.string("command_inspector.history_match"), systemImage: "scroll")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.accent)
                Spacer()
                Text(L10n.format("command_inspector.history_matches", result.matchCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(result.snippet)
                .font(.caption2.monospaced())
                .lineLimit(12)
                .textSelection(.enabled)

            HStack {
                Button(action: copySnippet) {
                    Label(L10n.string("command_inspector.copy_history"), systemImage: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }
}

private enum AIExplainContextScope: String, CaseIterable, Identifiable {
    case commandOnly
    case currentBlock
    case currentFilter

    var id: String { rawValue }

    var name: String {
        L10n.string("ai_explain.context_scope.\(rawValue)")
    }
}

private struct CommandBlockCard: View {
    let block: TerminalCommandBlock
    let skin: TerminalVisualSkin
    let displayOutput: String
    let displaySummary: String
    let diagnosticLine: String?
    let hasSensitiveOutput: Bool
    let copyCommand: () -> Void
    let copyOutput: () -> Void
    let copyAIContext: () -> Void
    let copyOutputSummary: () -> Void
    let stageCommand: () -> Void
    let explainCommand: () -> Void
    let isExplaining: Bool

    private var outputInsights: [TerminalOutputInsight] {
        TerminalOutputInsightAnalyzer.insights(in: displayOutput)
    }

    private var outputInsightKinds: [TerminalOutputInsightKind] {
        if let outputSummary = block.outputSummary, !outputSummary.insightKinds.isEmpty {
            return Array(outputSummary.insightKinds.prefix(5))
        }

        var kinds: [TerminalOutputInsightKind] = []
        for insight in outputInsights where !kinds.contains(insight.kind) {
            kinds.append(insight.kind)
        }
        return Array(kinds.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                statusDot
                Text(block.command)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(statusLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(statusColor)
            }

            if hasSensitiveOutput {
                Label(L10n.string("safety.sensitive_output.card"), systemImage: "exclamationmark.shield")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let diagnosticLine, isFailure {
                Label(diagnosticLine, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let workingDirectory = block.workingDirectory, !workingDirectory.isEmpty {
                    Label(workingDirectory, systemImage: "folder")
                        .lineLimit(1)
                }
                if let durationMilliseconds = block.durationMilliseconds {
                    Label(L10n.format("command_inspector.duration_ms", durationMilliseconds), systemImage: "timer")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !outputInsightKinds.isEmpty {
                HStack(spacing: 5) {
                    ForEach(outputInsightKinds, id: \.self) { kind in
                        Text(L10n.string(kind.labelKey))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(skin.selectionFill)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            if !displayOutput.isEmpty {
                Text(displayOutput)
                    .font(.caption2.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(skin.panelFill.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 8) {
                Button(action: copyCommand) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("command_inspector.copy_command"))

                Button(action: copyOutput) {
                    Image(systemName: "text.page")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(block.outputTail.isEmpty)
                .help(L10n.string("command_inspector.copy_output"))

                Button(action: copyAIContext) {
                    Image(systemName: "sparkles")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("command_inspector.copy_ai_context"))

                Button(action: copyOutputSummary) {
                    Image(systemName: "text.badge.checkmark")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(displaySummary.isEmpty)
                .help(L10n.string("command_inspector.copy_output_summary"))

                Button(action: stageCommand) {
                    Image(systemName: "arrow.turn.down.right")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("runbook.stage_command"))

                Button(action: explainCommand) {
                    if isExplaining {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 24, height: 22)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .frame(width: 24, height: 22)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExplaining)
                .help(L10n.string("ai_explain.button"))

                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        if block.endedAt == nil {
            return skin.accent
        }
        if isFailure {
            return .red.opacity(0.82)
        }
        return .green.opacity(0.78)
    }

    private var isFailure: Bool {
        if let exitCode = block.exitCode {
            return exitCode != 0
        }
        return false
    }

    private var statusLabel: String {
        if block.endedAt == nil {
            return L10n.string("command_inspector.status.running")
        }
        if let exitCode = block.exitCode {
            return exitCode == 0
                ? L10n.string("command_inspector.status.ok")
                : L10n.format("command_inspector.status.exit", exitCode)
        }
        return L10n.string("command_inspector.status.done")
    }
}

private struct IconButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

#Preview {
    ContentView()
}
