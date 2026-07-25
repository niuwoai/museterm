import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var workspace = TerminalWorkspace()
    @StateObject private var sshStore = SSHConnectionStore()
    @StateObject private var profileStore = TerminalProfileStore.shared
    @StateObject private var notificationCoordinator = TerminalNotificationCoordinator.shared
    @StateObject private var aiCommandAssistant = AICommandAssistantModel()
    @ObservedObject private var preferences: TerminalPreferences
    @State private var rightPanel: TerminalRightPanel?
    @State private var commandPalettePresentation = CommandPalettePresentationState()
    @State private var isSessionTunnelSheetPresented = false

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
                    profileStore: profileStore,
                    preferences: preferences,
                    onCreateSessionTunnel: presentSessionTunnelSheet
                )

                TerminalPaneView(
                    workspace: workspace,
                    preferences: preferences,
                    aiCommandAssistant: aiCommandAssistant
                )
                    .ignoresSafeArea(.container, edges: .top)

                if rightPanel == .sessionTunnel, let selectedTab = workspace.selectedTab {
                    SessionTunnelInspectorView(
                        tab: selectedTab,
                        preferences: preferences,
                        onDismiss: {
                            rightPanel = nil
                        }
                    )
                } else if rightPanel == .commandInspector {
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

            if commandPalettePresentation.isPresented {
                CommandPaletteView(
                    isPresented: $commandPalettePresentation.isPresented,
                    workspace: workspace,
                    sshStore: sshStore,
                    preferences: preferences
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .zIndex(20)
            }
        }
        .background(WindowConfigurator(workspace: workspace))
        .background(
            TerminalShortcutBridge(
                workspace: workspace,
                preferences: preferences,
                isCommandPaletteActive: { commandPalettePresentation.isPresented },
                onAICommandTrigger: beginAICommandAssistance,
                isAICommandActive: { aiCommandAssistant.isActive },
                onAICommandDismiss: { aiCommandAssistant.dismiss() }
            )
        )
        .focusedValue(\.terminalWorkspace, workspace)
        .sheet(isPresented: $isSessionTunnelSheetPresented) {
            if let selectedTab = workspace.selectedTab {
                SessionTunnelCreateSheet(
                    tab: selectedTab,
                    isPresented: $isSessionTunnelSheetPresented,
                    onStart: { configuration in
                        aiCommandAssistant.dismiss(showNotice: false)
                        commandPalettePresentation.dismiss()
                        try selectedTab.startSessionTunnel(configuration: configuration)
                        rightPanel = .sessionTunnel
                    }
                )
            }
        }
        .tint(preferences.skin.accent)
        .preferredColorScheme(preferences.skin.preferredColorScheme)
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            workspace.profileStore = profileStore
            workspace.preferences = preferences
            TerminalToolBridge.shared.attach(workspace: workspace)
            notificationCoordinator.attach(workspace: workspace, preferences: preferences)
            MuseTermScriptingRegistry.attach(
                workspace: workspace,
                preferences: preferences,
                sshStore: sshStore
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandInspector)) { _ in
            toggleRightPanel(.commandInspector)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTaskPortPanel)) { _ in
            toggleRightPanel(.tasks)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            aiCommandAssistant.dismiss(showNotice: false)
            withAnimation(.easeOut(duration: 0.12)) {
                commandPalettePresentation.present()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAICommandAssistant)) { _ in
            beginAICommandAssistance()
        }
        .onChange(of: workspace.selectedID) { selectedID in
            aiCommandAssistant.cancelIfTargetChanged(selectedID: selectedID)
            if workspace.selectedTab?.sessionTunnelStatus != nil {
                rightPanel = .sessionTunnel
            } else if rightPanel == .sessionTunnel {
                rightPanel = nil
            }
        }
    }

    private func beginAICommandAssistance() {
        guard !aiCommandAssistant.isActive,
              let selectedTab = workspace.selectedTab,
              selectedTab.sessionTunnelStatus?.occupiesTerminal != true else {
            return
        }
        rightPanel = nil
        commandPalettePresentation.dismiss()
        aiCommandAssistant.present(for: selectedTab)
    }

    private func toggleRightPanel(_ panel: TerminalRightPanel) {
        guard workspace.selectedTab?.sessionTunnelStatus?.occupiesTerminal != true else {
            rightPanel = .sessionTunnel
            return
        }
        aiCommandAssistant.dismiss(showNotice: false)
        rightPanel = rightPanel == panel ? nil : panel
    }

    private func presentSessionTunnelSheet() {
        guard let selectedTab = workspace.selectedTab else { return }
        if selectedTab.sessionTunnelStatus != nil {
            rightPanel = .sessionTunnel
            return
        }
        aiCommandAssistant.dismiss(showNotice: false)
        commandPalettePresentation.dismiss()
        rightPanel = nil
        isSessionTunnelSheetPresented = true
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
    case sessionTunnel
    case commandInspector
    case tasks
}

private struct SidebarView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var sshStore: SSHConnectionStore
    @ObservedObject var profileStore: TerminalProfileStore
    @ObservedObject var preferences: TerminalPreferences
    let onCreateSessionTunnel: () -> Void

    private enum Layout {
        static let collapsedWidth: CGFloat = 88
    }

    var body: some View {
        ZStack(alignment: .trailing) {
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
                                        closeAction: { workspace.close(tab) },
                                        detachAction: { detach(tab) }
                                    )
                                    .onTapGesture {
                                        workspace.select(tab)
                                    }
                                }
                            }

                            TerminalQuickPathSection(workspace: workspace, skin: preferences.skin)

                            LearnedCommandSidebarSection(
                                workspace: workspace,
                                sshStore: sshStore,
                                skin: preferences.skin
                            )

                            TerminalShortcutSection(
                                workspace: workspace,
                                sshStore: sshStore,
                                skin: preferences.skin
                            )

                            FileTransferSection(workspace: workspace, skin: preferences.skin)

                            TerminalProfilesSection(
                                workspace: workspace,
                                store: profileStore,
                                skin: preferences.skin
                            )

                            SSHProfilesSection(
                                workspace: workspace,
                                store: sshStore,
                                skin: preferences.skin
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                } else {
                    // 收起态保留一个窄版标签列表：只显示状态点 + 截断标题，
                    // 点击切换、右键关闭，悬停提示完整标题与 ⌘ 快捷键。
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                                CompactTabRowView(
                                    tab: tab,
                                    isSelected: workspace.selectedID == tab.id,
                                    shortcutNumber: index < 9 ? index + 1 : nil,
                                    skin: preferences.skin,
                                    closeAction: { workspace.close(tab) },
                                    detachAction: { detach(tab) }
                                )
                                .onTapGesture {
                                    workspace.select(tab)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }

                Spacer(minLength: 8)

                if preferences.showsTabList {
                    HStack {
                        Spacer()
                        settingsButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack {
                        settingsButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity)

            if preferences.showsTabList {
                SidebarResizeHandle(preferences: preferences)
            }
        }
        .frame(width: sidebarWidth)
        .background(preferences.skin.sidebarBackground)
    }

    private var sidebarWidth: CGFloat {
        preferences.showsTabList
            ? CGFloat(preferences.sidebarExpandedWidth)
            : Layout.collapsedWidth
    }

    private var settingsButton: some View {
        Button {
            SettingsWindowOpener.open(preferences: preferences)
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(L10n.string("action.settings"))
        .accessibilityLabel(L10n.string("action.settings"))
    }

    private func detach(_ tab: TerminalSession) {
        DetachedTerminalPanelManager.shared.detach(
            tab,
            workspace: workspace,
            preferences: preferences
        )
    }

    @ViewBuilder
    private var header: some View {
        if preferences.showsTabList {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L10n.string("app.name"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    IconButton(
                        systemName: "sidebar.left",
                        title: L10n.string("action.hide_tab_list")
                    ) {
                        preferences.showsTabList = false
                    }
                }

                HStack(spacing: 10) {
                    IconButton(systemName: "plus", title: L10n.string("action.new_tab")) {
                        workspace.newTab()
                    }
                    ProfileNewTabMenu(workspace: workspace, store: profileStore)
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
                        systemName: "arrow.left.arrow.right",
                        title: L10n.string("session_tunnel.create.action"),
                        action: onCreateSessionTunnel
                    )
                    .accessibilityIdentifier("sessionTunnelCreateButton")
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(spacing: 10) {
                IconButton(systemName: "sidebar.right", title: L10n.string("action.show_tab_list")) {
                    preferences.showsTabList = true
                }
                IconButton(systemName: "plus", title: L10n.string("action.new_tab")) {
                    workspace.newTab()
                }
                ProfileNewTabMenu(workspace: workspace, store: profileStore)
                IconButton(
                    systemName: "arrow.left.arrow.right",
                    title: L10n.string("session_tunnel.create.action"),
                    action: onCreateSessionTunnel
                )
                .accessibilityIdentifier("sessionTunnelCreateButton")
            }
        }
    }
}

private struct SidebarResizeHandle: View {
    @ObservedObject var preferences: TerminalPreferences
    @State private var isHovering = false
    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(preferences.skin.hairline.opacity(isHovering || dragStartWidth != nil ? 0.95 : 0.55))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = preferences.sidebarExpandedWidth
                        }
                        let startWidth = dragStartWidth ?? preferences.sidebarExpandedWidth
                        preferences.sidebarExpandedWidth = TerminalPreferences.clampedSidebarExpandedWidth(
                            startWidth + value.translation.width
                        )
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .help(L10n.string("sidebar.resize.help"))
            .accessibilityLabel(L10n.string("sidebar.resize.help"))
    }
}

/// 「按 Profile 开 tab」的下拉菜单：列出所有 profile，选中即以该 profile 新开标签。
private struct ProfileNewTabMenu: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var store: TerminalProfileStore

    var body: some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button {
                    workspace.newTab(profile: profile)
                } label: {
                    if profile.isDefault {
                        Label(profile.displayName, systemImage: "star.fill")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.stack.badge.plus")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("action.new_tab_with_profile"))
        .accessibilityLabel(L10n.string("action.new_tab_with_profile"))
    }
}

extension Notification.Name {
    static let showCommandPalette = Notification.Name("MuseTermShowCommandPalette")
    static let showAICommandAssistant = Notification.Name("MuseTermShowAICommandAssistant")
    static let toggleCommandInspector = Notification.Name("MuseTermToggleCommandInspector")
    static let toggleTaskPortPanel = Notification.Name("MuseTermToggleTaskPortPanel")
    // 设置页里撤销「拉黑」后广播；运行中的工作区据此重载黑名单并刷新最近/常用列表。
    static let recommendationBlacklistChanged = Notification.Name("MuseTermRecommendationBlacklistChanged")
}

private struct TabRowView: View {
    @ObservedObject var tab: TerminalSession
    let isSelected: Bool
    let shortcutNumber: Int?
    let skin: TerminalVisualSkin
    let closeAction: () -> Void
    let detachAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .overlay(alignment: .topTrailing) {
                    if tab.hasUnreadAttention && !isSelected {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -3)
                            .accessibilityLabel(L10n.string("tab.notification_unread"))
                    }
                }

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
                if tab.tabSubtitle != nil || tab.shellName != nil {
                    HStack(spacing: 5) {
                        if let shellName = tab.shellName {
                            ShellBadge(shellName: shellName, skin: skin)
                        }
                        if let subtitle = tab.tabSubtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if tab.sessionTunnelStatus?.occupiesTerminal == true {
                Image(systemName: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .help(L10n.string("session_tunnel.phase.running"))
                    .accessibilityLabel(L10n.string("session_tunnel.phase.running"))
            }

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
            .accessibilityLabel(L10n.string("action.close_tab"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(isSelected ? skin.tabSelectionFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.tabSelectionBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button(action: detachAction) {
                Label(L10n.string("action.detach_tab"), systemImage: "rectangle.on.rectangle.slash")
            }
            Divider()
            Button(role: .destructive, action: closeAction) {
                Label(L10n.string("action.close_tab"), systemImage: "xmark")
            }
        }
    }

    private var statusColor: Color {
        switch tab.state {
        case .running: return skin.accent
        case .exited: return .secondary.opacity(0.55)
        }
    }
}

private struct CompactTabRowView: View {
    @ObservedObject var tab: TerminalSession
    let isSelected: Bool
    let shortcutNumber: Int?
    let skin: TerminalVisualSkin
    let closeAction: () -> Void
    let detachAction: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .overlay(alignment: .topTrailing) {
                    if tab.hasUnreadAttention && !isSelected {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 4, height: 4)
                            .offset(x: 2, y: -2)
                            .accessibilityLabel(L10n.string("tab.notification_unread"))
                    }
                }

            Text(tab.tabTitle)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if tab.sessionTunnelStatus?.occupiesTerminal == true {
                Image(systemName: "link")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel(L10n.string("session_tunnel.phase.running"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(isSelected ? skin.tabSelectionFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? skin.tabSelectionBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(helpText)
        .contextMenu {
            Button(action: detachAction) {
                Label(L10n.string("action.detach_tab"), systemImage: "rectangle.on.rectangle.slash")
            }
            Divider()
            Button(role: .destructive, action: closeAction) {
                Label(L10n.string("action.close_tab"), systemImage: "xmark")
            }
        }
    }

    private var helpText: String {
        guard let shortcutNumber else { return tab.tabTitle }
        return "\(tab.tabTitle) ⌘\(shortcutNumber)"
    }

    private var statusColor: Color {
        switch tab.state {
        case .running: return skin.accent
        case .exited: return .secondary.opacity(0.55)
        }
    }
}

private struct ShellBadge: View {
    let shellName: String
    let skin: TerminalVisualSkin

    var body: some View {
        Text(shellName)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(skin.accent)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(skin.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.format("tab.shell.help", shellName))
    }
}

private struct TerminalPaneView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject var aiCommandAssistant: AICommandAssistantModel

    var body: some View {
        ZStack {
            preferences.skin.panelFill
            ForEach(workspace.tabs) { tab in
                let isSelected = workspace.selectedID == tab.id
                TerminalHostView(session: tab, preferences: preferences, isActive: isSelected)
                    .id(tab.id)
                    .allowsHitTesting(
                        isSelected && tab.sessionTunnelStatus?.occupiesTerminal != true
                    )
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
            if let selectedTab = workspace.selectedTab, selectedTab.canManuallyReconnectSSH {
                SSHReconnectOverlay(
                    tab: selectedTab,
                    skin: preferences.skin
                )
                .transition(.opacity)
                .zIndex(2)
            }
            if let selectedTab = workspace.selectedTab {
                SessionTunnelMaskContainer(tab: selectedTab, skin: preferences.skin)
                    .zIndex(40)
            }
            AICommandAssistantLayer(
                model: aiCommandAssistant,
                workspace: workspace,
                preferences: preferences
            )
            .zIndex(30)
        }
    }
}

private struct SSHReconnectOverlay: View {
    @ObservedObject var tab: TerminalSession
    let skin: TerminalVisualSkin

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(skin.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("ssh.reconnect.manual_title"))
                        .font(.caption.weight(.semibold))
                    Text(L10n.string("ssh.reconnect.manual_summary"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    tab.reconnectSSH()
                } label: {
                    Label(
                        L10n.string("ssh.reconnect.manual_button"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(skin.hairline, lineWidth: 1)
            )
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 20)
        .allowsHitTesting(true)
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
    @State private var showsAdvancedControls = false
    @State private var copiedMessage = ""
    @State private var copiedMessageGeneration = 0
    @State private var explainingBlockID: UUID?
    @State private var explainedCommand = ""
    @State private var aiExplanation = ""
    @State private var aiExplainError = ""
    @State private var aiContextScope: AIExplainContextScope = .currentBlock
    private let commandInspectorToggleColumns = [
        GridItem(.flexible(minimum: 124), spacing: 8, alignment: .leading),
        GridItem(.flexible(minimum: 124), spacing: 8, alignment: .leading)
    ]

    private var blocks: [TerminalCommandBlock] {
        guard let tab = workspace.selectedTab else { return [] }
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandQuery = TerminalCommandQuery(cleaned)
        return tab.commandBlocks
            .reversed()
            .filter { block in
                if failuresOnly, block.exitCode == nil || block.exitCode == 0 {
                    return false
                }
                guard !commandQuery.isEmpty else { return true }
                return commandQuery.matches(block)
            }
    }

    private var sensitiveOutputBlocks: [TerminalCommandBlock] {
        blocks.filter { RunbookSensitiveRedactor.containsSensitiveData($0.outputTail) }
    }

    private var historySearchResult: TerminalHistorySearchResult? {
        guard let tab = workspace.selectedTab, !failuresOnly else { return nil }
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let historyTextQuery = TerminalCommandQuery(cleaned).historyTextQuery else { return nil }
        return TerminalHistorySearchResult(
            query: historyTextQuery,
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
            .accessibilityLabel(L10n.string("action.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(L10n.string("command_inspector.search_placeholder"), text: $query)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                compactToggle("command_inspector.failures_only", isOn: $failuresOnly)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsAdvancedControls.toggle()
                    }
                } label: {
                    Label(
                        L10n.string("command_inspector.advanced"),
                        systemImage: showsAdvancedControls ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(preferences.skin.accent)
                .accessibilityValue(
                    L10n.string(showsAdvancedControls ? "accessibility.expanded" : "accessibility.collapsed")
                )
            }
            if showsAdvancedControls {
                advancedControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !copiedMessage.isEmpty {
                Text(copiedMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            aiExplainPanel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            optionToggles
            if includeReplayScript, parameterizeReplayScript {
                runbookVariableEditor
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
                .lineLimit(1...2)
            HStack(spacing: 8) {
                runbookActionButton(
                    titleKey: "runbook.copy",
                    systemImage: "doc.on.doc",
                    action: exportRunbookToClipboard
                )
                runbookActionButton(
                    titleKey: "runbook.save",
                    systemImage: "square.and.arrow.down",
                    action: saveRunbook
                )
                runbookActionButton(
                    titleKey: "runbook.copy_replay",
                    systemImage: "play.rectangle",
                    action: copyReplayScript
                )
            }
            sensitiveOutputPanel
        }
    }

    private var optionToggles: some View {
        LazyVGrid(columns: commandInspectorToggleColumns, alignment: .leading, spacing: 4) {
            compactToggle("runbook.redact_sensitive", isOn: $redactSensitiveData)
            compactToggle("runbook.include_replay_script", isOn: $includeReplayScript)
            if includeReplayScript {
                compactToggle("runbook.parameterize_paths", isOn: $parameterizeReplayScript)
                compactToggle("runbook.confirm_each_step", isOn: $confirmReplaySteps)
            }
        }
    }

    private func runbookActionButton(
        titleKey: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L10n.string(titleKey), systemImage: systemImage)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(preferences.skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(runbookExportBlocks.isEmpty)
    }

    private func compactToggle(_ titleKey: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(L10n.string(titleKey))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(L10n.string(titleKey))
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
                        .accessibilityLabel(L10n.string("action.close"))
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
            emptyState(
                title: L10n.string("command_inspector.no_tab.title"),
                detail: L10n.string("command_inspector.no_tab.detail")
            )
        } else if blocks.isEmpty, historySearchResult == nil {
            let hasFilter = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || failuresOnly
            emptyState(
                title: L10n.string(
                    hasFilter
                        ? "command_inspector.empty.filtered.title"
                        : "command_inspector.empty.title"
                ),
                detail: L10n.string(
                    hasFilter
                        ? "command_inspector.empty.filtered.detail"
                        : "command_inspector.empty.detail"
                )
            )
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

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
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
        showInspectorMessage(L10n.string(messageKey))
    }

    // 成功类反馈几秒后自动消失，错误提示保持常驻直到被下一条消息覆盖。
    private func showInspectorMessage(_ text: String, autoClears: Bool = true) {
        copiedMessage = text
        copiedMessageGeneration += 1
        guard autoClears else { return }
        let generation = copiedMessageGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard copiedMessageGeneration == generation else { return }
            copiedMessage = ""
        }
    }

    private var runbookExportBlocks: [TerminalCommandBlock] {
        blocks.reversed()
    }

    private var runbookVariableEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L10n.string("runbook.variables"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    runbookHomePath = ""
                    runbookWorkingDirectory = ""
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.string("runbook.reset_variables"))
                .accessibilityLabel(L10n.string("runbook.reset_variables"))
            }

            HStack(spacing: 6) {
                TextField(L10n.string("runbook.home_path"), text: $runbookHomePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                TextField(L10n.string("runbook.workdir_path"), text: $runbookWorkingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            Text(
                L10n.format(
                    "runbook.variable_defaults",
                    effectiveRunbookVariables.homePath,
                    effectiveRunbookVariables.workingDirectory ?? L10n.string("runbook.no_workdir")
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(6)
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
            showInspectorMessage(L10n.string("runbook.saved"))
        } catch {
            showInspectorMessage(L10n.format("runbook.save_failed", error.localizedDescription), autoClears: false)
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
                lines.append("  Lifecycle state: \(block.commandLifecycleState.contextLabel)")
                lines.append("  Risk level: \(block.commandRiskProfile.level.contextLabel)")
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
        showInspectorMessage(L10n.string("runbook.command_staged"))
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
                .help(L10n.string("command_inspector.tooltip.copy_command"))
                .accessibilityLabel(L10n.string("command_inspector.copy_command"))

                Button(action: copyOutput) {
                    Image(systemName: "text.page")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(block.outputTail.isEmpty)
                .help(L10n.string("command_inspector.tooltip.copy_output"))
                .accessibilityLabel(L10n.string("command_inspector.copy_output"))

                Button(action: copyAIContext) {
                    Image(systemName: "sparkles")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("command_inspector.tooltip.copy_ai_context"))
                .accessibilityLabel(L10n.string("command_inspector.copy_ai_context"))

                Button(action: copyOutputSummary) {
                    Image(systemName: "text.badge.checkmark")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(displaySummary.isEmpty)
                .help(L10n.string("command_inspector.tooltip.copy_output_summary"))
                .accessibilityLabel(L10n.string("command_inspector.copy_output_summary"))

                Button(action: stageCommand) {
                    Image(systemName: "arrow.turn.down.right")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("command_inspector.tooltip.stage_command"))
                .accessibilityLabel(L10n.string("runbook.stage_command"))

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
                .help(L10n.string("command_inspector.tooltip.explain_command"))
                .accessibilityLabel(L10n.string("ai_explain.button"))

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
        .accessibilityLabel(title)
    }
}

#Preview {
    ContentView()
}
