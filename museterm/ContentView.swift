import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = TerminalWorkspace()
    @ObservedObject private var preferences: TerminalPreferences

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
                    preferences: preferences
                )

                TerminalPaneView(workspace: workspace, preferences: preferences)
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
    }
}

private struct SidebarView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        VStack(spacing: 0) {
            header
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if preferences.showsTabList {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            TabRowView(
                                tab: tab,
                                isSelected: workspace.selectedID == tab.id,
                                skin: preferences.skin,
                                closeAction: { workspace.close(tab) }
                            )
                            .onTapGesture {
                                workspace.select(tab)
                            }
                        }
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

private struct TabRowView: View {
    @ObservedObject var tab: TerminalSession
    let isSelected: Bool
    let skin: TerminalVisualSkin
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.tabTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = tab.tabSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.string("action.close_tab"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(isSelected ? skin.selectionFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.hairline : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
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
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
        }
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
