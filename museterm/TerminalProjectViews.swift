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
    @State private var showsImport = false
    @State private var collapsedProjects: Set<UUID> = []
    @State private var showsProjects = true
    @State private var showsHiddenTerminals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            if showsProjects {
                ForEach(workspace.projectLayout.projects) { project in
                    projectGroup(project)
                }
            }
            let hiddenTabs = hiddenProjectTabs
            if !hiddenTabs.isEmpty {
                Button { showsHiddenTerminals.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsHiddenTerminals ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text(L10n.format("project.hidden_terminals", hiddenTabs.count))
                        Spacer(minLength: 0)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-hidden-terminals-toggle")
                if showsHiddenTerminals {
                    ForEach(hiddenTabs, id: \.id) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill").foregroundStyle(.secondary)
                            Text(workspace.sessionRegistry.sessions[item.layoutTab.focusedTerminalID]?.tabTitle ?? "")
                                .lineLimit(1)
                            Text(item.project.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Button(L10n.string("project.show_terminal")) {
                                for id in item.layoutTab.layout.terminalIDs {
                                    workspace.sessionRegistry.sessions[id]?.runtimeRestoreHidden = false
                                }
                                if let session = workspace.sessionRegistry.sessions[item.layoutTab.focusedTerminalID] {
                                    workspace.select(session)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("project-show-hidden-\(item.id)")
                        }
                        .font(.caption)
                        .padding(.leading, 14)
                    }
                }
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            TerminalProjectEditor(workspace: workspace, projectID: presentation.projectID)
        }
        .sheet(isPresented: $showsImport) { TerminalProjectImportView(workspace: workspace) }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                sectionToggle
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    sectionActions
                }
            }
        } else {
            HStack(spacing: 8) {
                sectionToggle
                Spacer(minLength: 0)
                sectionActions
            }
        }
    }

    private var sectionToggle: some View {
        Button { showsProjects.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: showsProjects ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                Text(L10n.string("project.section"))
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .help(L10n.string(showsProjects ? "project.collapse" : "project.expand"))
        .accessibilityIdentifier("project-section-toggle")
    }

    private var sectionActions: some View {
        let buttonSize: CGFloat = 24
        return HStack(spacing: 4) {
            Button { showsImport = true } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .help(L10n.string("project.import.title"))
            .accessibilityLabel(L10n.string("project.import.title"))
            .accessibilityIdentifier("project-import")
            Button { editorPresentation = .create } label: {
                Image(systemName: "plus")
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .help(L10n.string("project.create"))
            .accessibilityLabel(L10n.string("project.create"))
            .accessibilityIdentifier("project-create")
        }
        .fixedSize()
    }

    private func projectGroup(_ project: TerminalProject) -> some View {
        let agents = workspace.sessionRegistry.sessions.compactMapValues(\.agentStatus)
        let activity = TerminalProjectActivity(project: project, agents: agents, attention: workspace.sessionRegistry.attention.activeItems)
        return VStack(alignment: .leading, spacing: 4) {
            if workspace.projectLayout.projects.count > 1 || project.directory != nil || project.name != L10n.string("project.default") {
                projectHeader(project, activity: activity)
            }
            if !collapsedProjects.contains(project.id) {
                ForEach(project.tabs) { layoutTab in
                    if let tab = workspace.sessionRegistry.sessions[layoutTab.focusedTerminalID], !isHidden(layoutTab) {
                        terminalRow(tab, layoutTab: layoutTab)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var hiddenProjectTabs: [(id: UUID, layoutTab: TerminalProjectTab, project: TerminalProject)] {
        workspace.projectLayout.projects.flatMap { project in
            project.tabs.compactMap { layoutTab in
                isHidden(layoutTab) ? (layoutTab.id, layoutTab, project) : nil
            }
        }
    }

    private func isHidden(_ layoutTab: TerminalProjectTab) -> Bool {
        layoutTab.layout.terminalIDs.contains { workspace.sessionRegistry.sessions[$0]?.runtimeRestoreHidden == true }
    }

    private func projectHeader(_ project: TerminalProject, activity: TerminalProjectActivity) -> some View {
        Button { selectOrToggle(project) } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsedProjects.contains(project.id) ? "chevron.right" : "chevron.down").font(.system(size: 8))
                Image(systemName: project.id == workspace.projectLayout.selectedProjectID ? "folder.fill" : "folder")
                Text(project.name).lineLimit(1)
                Spacer(minLength: 0)
                if activity.needsAnswer > 0 { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
                else if activity.working > 0 { Image(systemName: "circle.dotted").foregroundStyle(.blue) }
                if activity.pending > 0 { Text(verbatim: "\(activity.pending)").monospacedDigit() }
            }
            .font(.caption.weight(.semibold)).padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-\(project.id)")
        .help(L10n.format("project.status", activity.working, activity.needsAnswer, activity.pending))
        .contextMenu {
            Button(L10n.string("project.new_tab")) { workspace.selectProject(project.id); workspace.newTab(startDirectory: project.directory) }
            Button(L10n.string("project.rename")) { editorPresentation = .rename(project.id) }
            Divider()
            Button(L10n.string("project.delete.action"), role: .destructive) { workspace.closeProject(project.id) }
        }
    }

    private func selectOrToggle(_ project: TerminalProject) {
        if collapsedProjects.contains(project.id) { collapsedProjects.remove(project.id) }
        else if workspace.projectLayout.selectedProjectID == project.id { collapsedProjects.insert(project.id) }
        workspace.selectProject(project.id)
        if project.tabs.isEmpty { workspace.newTab(startDirectory: project.directory) }
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
                    catch { NSLog("MuseTerm project terminal move failed") }
                }
            }
        }
        Button(L10n.string("project.detach_terminal")) { onDetach(tab) }
        Button(L10n.string("project.close_tab.title"), role: .destructive) { workspace.closeLayoutTab(layoutTab.id) }
    }

    private func split(_ tab: TerminalSession, axis: TerminalSplitAxis) {
        do { try workspace.splitTerminal(tab.id, axis: axis) }
        catch { NSLog("MuseTerm project terminal split failed") }
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
