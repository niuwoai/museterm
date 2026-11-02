import SwiftUI

struct TerminalProjectCanvas: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        ZStack {
            if workspace.runtimeRecoveryIssue {
                VStack {
                    HStack {
                        Text(L10n.string("runtime.workspace.recovery_issue"))
                        Button(L10n.string("runtime.dismiss")) { workspace.runtimeRecoveryIssue = false }
                    }
                    .font(.caption).padding(10).background(.regularMaterial)
                    Spacer()
                }.zIndex(2)
            }
            ForEach(workspace.projectLayout.projects.flatMap(\.tabs)) { tab in
                let hidden = tab.layout.terminalIDs.contains {
                    workspace.sessionRegistry.sessions[$0]?.runtimeRestoreHidden == true
                }
                if !hidden {
                    let visible = workspace.projectLayout.selectedTab?.id == tab.id
                    TerminalPaneTree(workspace: workspace, preferences: preferences, layout: tab.layout, visible: visible)
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                        .opacity(visible ? 1 : 0)
                        .zIndex(visible ? 1 : 0)
                }
            }
            if workspace.runtimeDiscoveryInProgress {
                ProgressView(L10n.string("runtime.discovering"))
                    .padding().background(.regularMaterial).zIndex(3)
            } else if workspace.projectLayout.selectedTab == nil || selectedTabIsHidden {
                Button(L10n.string("project.new_tab")) {
                    workspace.newTab(startDirectory: workspace.projectLayout.selectedProject?.directory)
                }
            }
        }
    }

    private var selectedTabIsHidden: Bool {
        guard let tab = workspace.projectLayout.selectedTab else { return false }
        return tab.layout.terminalIDs.contains { workspace.sessionRegistry.sessions[$0]?.runtimeRestoreHidden == true }
    }
}

private struct TerminalPaneTree: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    let layout: TerminalPaneLayout
    let visible: Bool

    var body: some View {
        switch layout {
        case .terminal(let id):
            if let session = workspace.tabs.first(where: { $0.id == id }) {
                TerminalProjectLeaf(workspace: workspace, preferences: preferences, session: session, visible: visible)
                    .id(id)
            } else if let session = workspace.sessionRegistry.sessions[id], workspace.sessionRegistry.locations[id] == .detached {
                VStack(spacing: 12) {
                    Text(session.tabTitle)
                    Button(L10n.string("runtime.workspace.show_panel")) { _ = DetachedTerminalPanelManager.shared.focus(id) }
                    Button(L10n.string("runtime.workspace.reattach")) { DetachedTerminalPanelManager.shared.reattach(session) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let horizontal = axis == .horizontal
                let total = max(1, (horizontal ? geometry.size.width : geometry.size.height) - 5)
                if horizontal {
                    HStack(spacing: 0) {
                        child(first).frame(width: total * ratio)
                        divider(id, axis: axis, ratio: ratio, total: total).frame(width: 5)
                        child(second).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        child(first).frame(height: total * ratio)
                        divider(id, axis: axis, ratio: ratio, total: total).frame(height: 5)
                        child(second).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func child(_ layout: TerminalPaneLayout) -> AnyView {
        AnyView(TerminalPaneTree(workspace: workspace, preferences: preferences, layout: layout, visible: visible))
    }

    private func divider(_ id: UUID, axis: TerminalSplitAxis, ratio: Double, total: Double) -> some View {
        TerminalProjectDivider(axis: axis, ratio: ratio, total: total) { workspace.resizeSplit(id, ratio: $0) }
            .accessibilityIdentifier("pane-divider-\(id)")
    }
}

private struct TerminalProjectDivider: View {
    let axis: TerminalSplitAxis
    let ratio: Double
    let total: Double
    let resize: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        Rectangle().fill(.quaternary).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil { dragStart = ratio }
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                resize((dragStart ?? ratio) + delta / total)
            }.onEnded { _ in dragStart = nil })
            .accessibilityLabel(L10n.string("project.resize"))
    }
}

private struct TerminalProjectLeaf: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject var session: TerminalSession
    let visible: Bool

    var body: some View {
        let focused = workspace.selectedID == session.id
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { workspace.select(session) } label: { Text(session.tabTitle).lineLimit(1) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pane-focus-\(session.id)")
                if let state = session.agentStatus { TerminalAgentBadge(status: state, compact: true) }
                if session.runtimeAttachOnly { Text(L10n.string("runtime.attach_only")).font(.caption2) }
                Spacer(minLength: 0)
                Button { split(.horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help(L10n.string("project.split_right"))
                    .accessibilityLabel(L10n.string("project.split_right"))
                    .accessibilityIdentifier("pane-split-right-\(session.id)")
                    .disabled(session.runtimeAttachOnly)
                Button { split(.vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help(L10n.string("project.split_down"))
                    .accessibilityLabel(L10n.string("project.split_down"))
                    .accessibilityIdentifier("pane-split-down-\(session.id)")
                    .disabled(session.runtimeAttachOnly)
                Menu {
                    ForEach(workspace.projectLayout.projects) { project in
                        Button(project.name) {
                            do { try workspace.moveTerminal(session.id, to: project.id) }
                            catch { NSLog("MuseTerm pane move failed") }
                        }
                    }
                } label: { Image(systemName: "folder") }
                    .help(L10n.string("project.move_terminal"))
                    .accessibilityLabel(L10n.string("project.move_terminal"))
                Button { workspace.close(session) } label: { Image(systemName: "xmark") }
                    .help(L10n.string("project.close_pane"))
                    .accessibilityLabel(L10n.string("project.close_pane"))
                    .accessibilityIdentifier("pane-close-\(session.id)")
            }
            .font(.caption).buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5)
            .background(focused ? preferences.skin.tabSelectionFill : Color.clear)
            TerminalRuntimeIssueView(session: session)
            ZStack {
                TerminalHostView(session: session, preferences: preferences, isActive: visible, focusesInput: focused)
                    .allowsHitTesting(session.sessionTunnelStatus?.occupiesTerminal != true)
                if session.canManuallyReconnectSSH { SSHReconnectOverlay(tab: session, skin: preferences.skin) }
                TerminalAIControlMask(tab: session, skin: preferences.skin)
                SessionTunnelMaskContainer(tab: session, skin: preferences.skin)
            }
        }
        .overlay(Rectangle().stroke(focused ? preferences.skin.tabSelectionBorder : .clear, lineWidth: 1).allowsHitTesting(false))
    }

    private func split(_ axis: TerminalSplitAxis) {
        do { try workspace.splitTerminal(session.id, axis: axis) }
        catch { NSLog("MuseTerm pane split failed") }
    }
}
