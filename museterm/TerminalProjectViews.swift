import SwiftUI

private enum TerminalProjectEditorPresentation: Hashable, Identifiable {
    case create
    case rename(UUID)

    var id: Self { self }
    var projectID: UUID? {
        if case .rename(let id) = self { return id }
        return nil
    }
}

struct TerminalProjectsSidebar: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    let compact: Bool
    let onDetach: (TerminalSession) -> Void
    @State private var editorPresentation: TerminalProjectEditorPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                editorPresentation = .create
            } label: { Label(L10n.string("project.create"), systemImage: "folder.badge.plus") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-create")
                .help(L10n.string("project.create"))
            ForEach(workspace.projectLayout.projects) { project in
                projectGroup(project)
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            TerminalProjectEditor(workspace: workspace, projectID: presentation.projectID)
        }
    }

    private func projectGroup(_ project: TerminalProject) -> some View {
        let agents = workspace.sessionRegistry.sessions.compactMapValues(\.agentStatus)
        let activity = TerminalProjectActivity(project: project, agents: agents, attention: workspace.sessionRegistry.attention.activeItems)
        return VStack(alignment: .leading, spacing: 4) {
            Button { workspace.selectProject(project.id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: project.id == workspace.projectLayout.selectedProjectID ? "folder.fill" : "folder")
                    Text(project.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if activity.needsAnswer > 0 { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
                    else if activity.working > 0 { Image(systemName: "circle.dotted").foregroundStyle(.blue) }
                    if activity.pending > 0 { Text(verbatim: "\(activity.pending)").monospacedDigit() }
                }
                .font(.caption.weight(.semibold))
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-\(project.id)")
            .help(L10n.format("project.status", activity.working, activity.needsAnswer, activity.pending))
            .contextMenu {
                Button(L10n.string("project.new_tab")) { workspace.selectProject(project.id); workspace.newTab(startDirectory: project.directory) }
                Button(L10n.string("project.rename")) { editorPresentation = .rename(project.id) }
                Divider()
                Button(L10n.string("project.close.action"), role: .destructive) { workspace.closeProject(project.id) }
            }
            ForEach(project.tabs) { layoutTab in
                if let tab = workspace.sessionRegistry.sessions[layoutTab.focusedTerminalID] {
                    terminalRow(tab, layoutTab: layoutTab)
                }
            }
            if project.tabs.isEmpty {
                Button(L10n.string("project.new_tab")) { workspace.selectProject(project.id); workspace.newTab(startDirectory: project.directory) }
                    .buttonStyle(.plain).font(.caption)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func terminalRow(_ tab: TerminalSession, layoutTab: TerminalProjectTab) -> some View {
        let selected = workspace.projectLayout.selectedTab?.id == layoutTab.id
        let shortcut = workspace.tabs.firstIndex(where: { $0.id == tab.id }).flatMap { $0 < 9 ? $0 + 1 : nil }
        VStack(alignment: .leading, spacing: 2) {
            if compact {
                CompactTabRowView(tab: tab, isSelected: selected,
                    showsUnreadBadge: preferences.notificationsEnabled && preferences.showInactiveTabNotificationBadges,
                    shortcutNumber: shortcut, skin: preferences.skin,
                    closeAction: { workspace.closeLayoutTab(layoutTab.id) }, detachAction: { onDetach(tab) },
                    contextMenuContent: AnyView(projectTabMenu(tab, layoutTab: layoutTab)))
            } else {
                TabRowView(tab: tab, isSelected: selected,
                    showsUnreadBadge: preferences.notificationsEnabled && preferences.showInactiveTabNotificationBadges,
                    shortcutNumber: shortcut, skin: preferences.skin,
                    closeAction: { workspace.closeLayoutTab(layoutTab.id) }, detachAction: { onDetach(tab) },
                    contextMenuContent: AnyView(projectTabMenu(tab, layoutTab: layoutTab)))
            }
            if layoutTab.layout.terminalIDs.count > 1 {
                Text(L10n.format("project.pane_count", layoutTab.layout.terminalIDs.count))
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.select(tab)
            if workspace.sessionRegistry.locations[tab.id] == .detached { _ = DetachedTerminalPanelManager.shared.focus(tab.id) }
        }
        .accessibilityIdentifier("project-tab-\(layoutTab.id)")
    }

    // The menu belongs to the row that receives the click. An outer context
    // menu is shadowed by the row's default detach/close menu on macOS.
    @ViewBuilder
    private func projectTabMenu(_ tab: TerminalSession, layoutTab: TerminalProjectTab) -> some View {
        Button(L10n.string("project.split_right")) { split(tab, axis: .horizontal) }
            .disabled(tab.runtimeAttachOnly)
        Button(L10n.string("project.split_down")) { split(tab, axis: .vertical) }
            .disabled(tab.runtimeAttachOnly)
        Menu(L10n.string("project.move_terminal")) {
            ForEach(workspace.projectLayout.projects) { project in
                Button(project.name) {
                    do { try workspace.moveTerminal(tab.id, to: project.id) }
                    catch { NSLog("QTerm project terminal move failed") }
                }
            }
        }
        Button(L10n.string("project.detach_terminal")) { onDetach(tab) }
        Button(L10n.string("project.close_tab.title"), role: .destructive) { workspace.closeLayoutTab(layoutTab.id) }
    }

    private func split(_ tab: TerminalSession, axis: TerminalSplitAxis) {
        do { try workspace.splitTerminal(tab.id, axis: axis) }
        catch { NSLog("QTerm project terminal split failed") }
    }
}

private struct TerminalProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: TerminalWorkspace
    let projectID: UUID?
    @State private var name = ""
    @State private var directory = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string(projectID == nil ? "project.create" : "project.rename")).font(.headline)
            TextField(L10n.string("project.name"), text: $name).accessibilityIdentifier("project-name")
            if projectID == nil {
                TextField(L10n.string("project.directory"), text: $directory).accessibilityIdentifier("project-directory")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L10n.string("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("project.save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("project-save")
            }
        }
        .padding(20).frame(width: 360)
        .onAppear {
            if let project = workspace.projectLayout.projects.first(where: { $0.id == projectID }) {
                name = project.name
                directory = project.directory ?? ""
            }
        }
    }

    private func save() {
        let clean = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if projectID == nil && !clean.isEmpty && TerminalWorkingDirectory.normalizedExistingDirectory(clean) == nil {
            errorMessage = L10n.string("project.invalid_directory"); return
        }
        do {
            if let projectID { try workspace.renameProject(projectID, name: name) }
            else { try workspace.createProject(name: name, directory: clean.isEmpty ? nil : clean) }
            dismiss()
        } catch { errorMessage = L10n.string("project.invalid_layout") }
    }
}
