import AppKit
import Combine
import SwiftUI

final class SettingsWindowSession: ObservableObject {
    @Published var aiAPIKeyDraft = ""
    @Published var aiStatusMessage = ""

    @discardableResult
    func savePendingAIAPIKey(preferences: TerminalPreferences) -> Bool {
        let trimmed = aiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        guard preferences.saveAIAPIKey(trimmed) else {
            aiStatusMessage = L10n.string("settings.ai.api_key.save_failed")
            return false
        }
        aiAPIKeyDraft = ""
        aiStatusMessage = L10n.string("settings.ai.api_key.save_success")
        return true
    }
}

struct SettingsView: View {
    static let defaultWindowSize = CGSize(width: 980, height: 680)

    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject var profileStore: TerminalProfileStore
    @ObservedObject var session: SettingsWindowSession
    @ObservedObject private var notificationCoordinator = TerminalNotificationCoordinator.shared
    @State private var selectedSettingsTab: SettingsTab = .appearance
    @State private var settingsSearchQuery = ""
    @State private var skinFilter: SkinAppearanceFilter = .all
    @State private var cliInstallMessage = ""
    @State private var toolBridgeAccessMessage = ""
    @State private var isBuiltInToolClientPaired = TerminalToolAccess.isPaired()
    @State private var editingProfile: TerminalProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                SettingsSidebar(
                    selection: $selectedSettingsTab,
                    searchQuery: $settingsSearchQuery,
                    skin: preferences.skin
                )
                Divider()
                    .padding(.horizontal, 14)
                settingsPage {
                    settingsContent
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height)
        .background(preferences.skin.panelFill)
        .tint(preferences.skin.accent)
        .preferredColorScheme(preferences.skin.preferredColorScheme)
        .focusable(false)
        .sheet(item: $editingProfile) { profile in
            TerminalProfileEditorSheet(
                profile: profile,
                onCancel: { editingProfile = nil },
                onSave: { edited in
                    profileStore.upsert(edited)
                    editingProfile = nil
                }
            )
        }
    }

    private var header: some View {
        HStack {
            Label(L10n.string("settings.title"), systemImage: "slider.horizontal.3")
                .font(.title3.weight(.semibold))
            Spacer()
            Text(AppVersion.displayValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSettingsTab {
        case .appearance:
            skinSection
        case .appIcon:
            appIconSection
        case .typography:
            fontSection
        case .glass:
            glassSection
        case .floatingPanel:
            floatingPanelSection
        case .behavior:
            behaviorSection
        case .sidebar:
            sidebarSectionSettings
        case .profiles:
            profilesSection
        case .notifications:
            notificationsSection
        case .ai:
            aiSection
        case .tools:
            toolsSection
        }
    }

    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("settings.skin"))
                    .font(.headline)
                Spacer()
                Text(L10n.format("settings.skin.count", TerminalVisualSkin.allCases.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(L10n.string("settings.skin.filter"), selection: $skinFilter) {
                ForEach(SkinAppearanceFilter.allCases) { filter in
                    Text(L10n.string("settings.skin.filter.\(filter.rawValue)"))
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TerminalVisualSkin.allCases.filter(skinFilter.includes)) { skin in
                    Button {
                        preferences.skin = skin
                    } label: {
                        SkinChoiceView(skin: skin, isSelected: preferences.skin == skin)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("settings.app_icon"))
                .font(.headline)
            Text(L10n.string("settings.app_icon.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        preferences.appIcon = choice
                    } label: {
                        AppIconChoiceView(
                            choice: choice,
                            isSelected: preferences.appIcon == choice,
                            skin: preferences.skin
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("settings.fonts"))
                .font(.headline)
            FontFamilyPicker(
                title: L10n.string("settings.primary_font"),
                selection: $preferences.fontFamily
            )
            FallbackFontListEditor(
                title: L10n.string("settings.fallback_font"),
                families: $preferences.fallbackFontFamilies
            )
            SliderRow(
                title: L10n.string("settings.font_size"),
                value: $preferences.fontSize,
                range: 9...28,
                format: "%.0f pt"
            )
            SliderRow(
                title: L10n.string("settings.line_height"),
                value: $preferences.lineHeight,
                range: 0.9...1.6,
                format: "%.2fx"
            )
            Text(L10n.string("settings.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var glassSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.string("settings.glass_enabled"), isOn: $preferences.glassEnabled)
                .font(.headline)

            Text(L10n.string("settings.transparency_help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SliderRow(
                title: L10n.string("settings.window_opacity"),
                value: $preferences.windowOpacity,
                range: 0.2...1,
                format: "%.0f%%",
                multiplier: 100
            )

            SliderRow(
                title: L10n.string("settings.terminal_opacity"),
                value: $preferences.terminalOpacity,
                range: 0.1...1,
                format: "%.0f%%",
                multiplier: 100
            )

            Picker(L10n.string("settings.glass_material"), selection: $preferences.glassMaterial) {
                ForEach(GlassMaterial.allCases) { material in
                    Text(material.name).tag(material)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!preferences.glassEnabled)

            SliderRow(
                title: L10n.string("settings.glass_opacity"),
                value: $preferences.glassOpacity,
                range: 0.2...1,
                format: "%.0f%%",
                multiplier: 100
            )
            .disabled(!preferences.glassEnabled)

            SliderRow(
                title: L10n.string("settings.tint_opacity"),
                value: $preferences.tintOpacity,
                range: 0...0.45,
                format: "%.0f%%",
                multiplier: 100
            )

            SliderRow(
                title: L10n.string("settings.glow"),
                value: $preferences.glow,
                range: 0...0.6,
                format: "%.0f%%",
                multiplier: 100
            )
        }
    }

    private var floatingPanelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("settings.floating_panel"))
                .font(.headline)
            Text(L10n.string("settings.floating_panel.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SliderRow(
                title: L10n.string("settings.floating_panel.opacity"),
                value: $preferences.detachedPanelOpacity,
                range: 0.2...1,
                format: "%.0f%%",
                multiplier: 100
            )
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("settings.behavior"))
                .font(.headline)
            Toggle(L10n.string("settings.show_tab_list"), isOn: $preferences.showsTabList)
            Toggle(L10n.string("settings.option_as_meta"), isOn: $preferences.optionAsMeta)
            Toggle(L10n.string("settings.mouse_reporting"), isOn: $preferences.mouseReporting)
            Toggle(L10n.string("settings.copy_on_select"), isOn: $preferences.copyOnSelect)
                .help(L10n.string("settings.copy_on_select.help"))
            Toggle(L10n.string("settings.open_web_images_in_viewer"), isOn: $preferences.openWebImagesInViewer)
                .help(L10n.string("settings.open_web_images_in_viewer.help"))
            inlineImagesRow
            scrollbackLinesRow
            primaryShortcutSection
            lineNavigationShortcutSection
            Toggle(L10n.string("settings.confirm_multiline_paste"), isOn: $preferences.confirmMultilinePaste)
            Toggle(L10n.string("settings.confirm_dangerous_commands"), isOn: $preferences.confirmDangerousCommands)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("settings.custom_dangerous_rules"))
                    .font(.caption.weight(.semibold))
                Text(L10n.string("settings.custom_dangerous_rules.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $preferences.customDangerousCommandRules)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 82, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .background(preferences.skin.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(preferences.skin.hairline, lineWidth: 1)
                    )
            }
            .disabled(!preferences.confirmDangerousCommands)

            HStack {
                Text(L10n.string("settings.cursor_shape"))
                Spacer()
                Picker(L10n.string("settings.cursor_shape"), selection: $preferences.cursorShape) {
                    ForEach(TerminalCursorShape.allCases) { shape in
                        Text(shape.name).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            .padding(.top, 4)
            Toggle(L10n.string("settings.cursor_blink"), isOn: $preferences.cursorBlink)

            Divider().padding(.vertical, 4)
            RecommendationBlacklistManagerView(skin: preferences.skin)
        }
    }

    /// 侧栏分区的显示和顺序。开关和上下移动都直接改偏好，侧栏跟着变。
    private var sidebarSectionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("settings.sidebar_sections"))
                .font(.headline)
            Text(L10n.string("settings.sidebar_sections.summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(preferences.sidebarSectionOrder) { section in
                sidebarSectionRow(section)
            }
        }
    }

    private func sidebarSectionRow(_ section: SidebarSectionKind) -> some View {
        let isFirst = preferences.sidebarSectionOrder.first == section
        let isLast = preferences.sidebarSectionOrder.last == section
        return HStack(spacing: 8) {
            Image(systemName: section.systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(L10n.string(section.titleKey))
                .font(.body)
            Spacer(minLength: 8)
            Button {
                preferences.moveSidebarSection(section, direction: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(isFirst)
            .help(L10n.string("settings.sidebar_sections.move_up"))
            Button {
                preferences.moveSidebarSection(section, direction: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(isLast)
            .help(L10n.string("settings.sidebar_sections.move_down"))
            Toggle(
                L10n.string("settings.sidebar_sections.visible"),
                isOn: Binding(
                    get: { preferences.isSidebarSectionVisible(section) },
                    set: { preferences.setSidebarSection(section, visible: $0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .help(L10n.string("settings.sidebar_sections.visible.help"))
            .accessibilityLabel(L10n.string("settings.sidebar_sections.visible"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(preferences.skin.controlFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var scrollbackLinesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("settings.scrollback_lines"))
                Spacer()
                Stepper(
                    value: $preferences.scrollbackLines,
                    in: TerminalPreferences.minimumScrollbackLines...TerminalPreferences.maximumScrollbackLines,
                    step: 500
                ) {
                    Text(L10n.format("settings.scrollback_lines.value", preferences.scrollbackLines))
                        .font(.body.monospacedDigit())
                }
                .frame(width: 190)
            }
            Text(L10n.format(
                "settings.scrollback_lines.help",
                TerminalPreferences.defaultScrollbackLines,
                TerminalPreferences.maximumScrollbackLines
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var inlineImagesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("settings.inline_images"))
                    Text(L10n.string("settings.inline_images.protocols"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(
                    value: $preferences.imageCacheMegabytes,
                    in: TerminalPreferences.minimumImageCacheMegabytes...TerminalPreferences.maximumImageCacheMegabytes,
                    step: TerminalPreferences.imageCacheStepMegabytes
                ) {
                    Text(L10n.format(
                        "settings.inline_images.cache_value",
                        preferences.imageCacheMegabytes
                    ))
                    .font(.body.monospacedDigit())
                }
                .frame(width: 190)
            }
            Text(L10n.format(
                "settings.inline_images.help",
                TerminalPreferences.defaultImageCacheMegabytes,
                TerminalPreferences.maximumImageCacheMegabytes
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var lineNavigationShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("settings.line_navigation.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(L10n.string("settings.line_navigation.restore_defaults")) {
                    preferences.setLineNavigationShortcut(
                        TerminalKeyBinding.defaultLineStart.storageValue,
                        for: .lineStart
                    )
                    preferences.setLineNavigationShortcut(
                        TerminalKeyBinding.defaultLineEnd.storageValue,
                        for: .lineEnd
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Text(L10n.string("settings.line_navigation.description"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            lineNavigationShortcutRow(
                title: L10n.string("settings.line_navigation.line_start"),
                shortcut: Binding(
                    get: { preferences.lineStartShortcut },
                    set: { newValue in
                        preferences.setLineNavigationShortcut(newValue, for: .lineStart)
                    }
                )
            )
            lineNavigationShortcutRow(
                title: L10n.string("settings.line_navigation.line_end"),
                shortcut: Binding(
                    get: { preferences.lineEndShortcut },
                    set: { newValue in
                        preferences.setLineNavigationShortcut(newValue, for: .lineEnd)
                    }
                )
            )

            if !preferences.lineStartShortcut.isEmpty,
               preferences.lineStartShortcut == preferences.lineEndShortcut {
                Label(L10n.string("settings.line_navigation.conflict"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(preferences.skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(preferences.skin.hairline, lineWidth: 1)
        )
    }

    private var primaryShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("settings.primary_shortcuts.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(L10n.string("settings.primary_shortcuts.restore_defaults")) {
                    preferences.restoreDefaultAppShortcuts()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Text(L10n.string("settings.primary_shortcuts.description"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(TerminalAppShortcutAction.allCases) { action in
                shortcutRow(
                    title: L10n.string(action.titleKey),
                    shortcut: Binding(
                        get: { preferences.appShortcut(for: action) },
                        set: { preferences.setAppShortcut($0, for: action) }
                    )
                )
            }

            Divider()

            HStack {
                Text(L10n.string("settings.ai_command.activation.title"))
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $preferences.aiCommandActivation) {
                    ForEach(AICommandActivation.allCases) { activation in
                        Text(L10n.string(activation.titleKey)).tag(activation)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text(L10n.string("settings.ai_command.activation.help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.string("settings.primary_shortcuts.reserved_help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(preferences.skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(preferences.skin.hairline, lineWidth: 1)
        )
    }

    private func lineNavigationShortcutRow(title: String, shortcut: Binding<String>) -> some View {
        shortcutRow(title: title, shortcut: shortcut)
    }

    private func shortcutRow(title: String, shortcut: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            TerminalKeyShortcutRecorder(storageValue: shortcut)
                .frame(width: 150, height: 26)
        }
    }

    private var aiSection: some View {
        AIProviderSettingsSection(
            preferences: preferences,
            apiKeyDraft: $session.aiAPIKeyDraft,
            statusMessage: $session.aiStatusMessage,
            onSaveAPIKey: {
                session.savePendingAIAPIKey(preferences: preferences)
            }
        )
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("settings.notifications"))
                    .font(.headline)
                Spacer()
                Label(
                    notificationCoordinator.authorizationStatusLabel,
                    systemImage: notificationCoordinator.authorizationStatusSystemImage
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(notificationCoordinator.canRequestAuthorization ? .secondary : preferences.skin.accent)
            }

            Text(L10n.string("settings.notifications.summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.string("settings.notifications.enabled"), isOn: $preferences.notificationsEnabled)
            Toggle(L10n.string("settings.agent_monitoring"), isOn: $preferences.agentMonitoringEnabled)
            Toggle(L10n.string("settings.notifications.agent_attention"), isOn: $preferences.notifyAgentAttention)
            Toggle(L10n.string("settings.notifications.inactive_tab_badges"), isOn: $preferences.showInactiveTabNotificationBadges)
                .disabled(!preferences.notificationsEnabled)

            HStack(spacing: 10) {
                Button {
                    notificationCoordinator.requestAuthorization()
                } label: {
                    Label(L10n.string("settings.notifications.request_permission"), systemImage: "bell.badge")
                }
                .disabled(!notificationCoordinator.canRequestAuthorization)

                Button {
                    notificationCoordinator.openNotificationSettings()
                } label: {
                    Label(L10n.string("settings.notifications.open_system_settings"), systemImage: "gearshape")
                }
            }
            .disabled(!preferences.notificationsEnabled)

            Divider()
                .padding(.vertical, 2)

            Text(L10n.string("settings.notifications.events"))
                .font(.subheadline.weight(.semibold))
            Toggle(L10n.string("settings.notifications.terminal_bell"), isOn: $preferences.notifyTerminalBell)
            Toggle(L10n.string("settings.notifications.command_failures"), isOn: $preferences.notifyCommandFailures)
            Toggle(L10n.string("settings.notifications.long_command_completion"), isOn: $preferences.notifyLongCommandCompletion)
            Toggle(L10n.string("settings.notifications.process_exits"), isOn: $preferences.notifyProcessExits)

            Divider()
                .padding(.vertical, 2)

            Text(L10n.string("settings.notifications.fatigue_controls"))
                .font(.subheadline.weight(.semibold))
            SliderRow(
                title: L10n.string("settings.notifications.long_command_threshold"),
                value: $preferences.longCommandNotificationThresholdSeconds,
                range: 10...180,
                format: "%.0fs"
            )
            SliderRow(
                title: L10n.string("settings.notifications.failure_min_duration"),
                value: $preferences.failureNotificationMinimumDurationSeconds,
                range: 0...60,
                format: "%.0fs"
            )
            SliderRow(
                title: L10n.string("settings.notifications.cooldown"),
                value: $preferences.notificationCooldownSeconds,
                range: 0...120,
                format: "%.0fs"
            )
            Toggle(L10n.string("settings.notifications.include_command"), isOn: $preferences.includeCommandInNotifications)
            Text(L10n.string("settings.notifications.privacy_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("settings.tools"))
                    .font(.headline)
                Spacer()
                statusBadge
            }

            Text(L10n.string("settings.tools.summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        L10n.string("settings.tools.access_control"),
                        systemImage: "lock.shield"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Label(
                        L10n.string(
                            isBuiltInToolClientPaired
                                ? "settings.tools.client_paired"
                                : "settings.tools.client_unpaired"
                        ),
                        systemImage: isBuiltInToolClientPaired
                            ? "checkmark.seal.fill"
                            : "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(isBuiltInToolClientPaired ? .green : .secondary)
                }

                Toggle(
                    L10n.string("settings.tools.allow_paired_writes"),
                    isOn: $preferences.toolBridgeWritesEnabled
                )
                Text(L10n.string("settings.tools.allow_paired_writes_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if isBuiltInToolClientPaired {
                        Button(role: .destructive) {
                            TerminalToolAccess.revoke()
                            isBuiltInToolClientPaired = false
                            toolBridgeAccessMessage = L10n.string("settings.tools.client_revoked")
                        } label: {
                            Label(L10n.string("settings.tools.revoke_client"), systemImage: "person.crop.circle.badge.minus")
                        }
                    } else {
                        Button {
                            pairBuiltInToolClient()
                        } label: {
                            Label(L10n.string("settings.tools.pair_client"), systemImage: "person.badge.key")
                        }
                    }
                    Text(L10n.string("settings.tools.client_name"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if !toolBridgeAccessMessage.isEmpty {
                    Text(toolBridgeAccessMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCodeRow(
                    title: L10n.string("settings.tools.audit_path"),
                    value: TerminalToolAccess.auditFile.path
                )
            }
            .padding(10)
            .background(preferences.skin.controlFill.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(preferences.skin.hairline, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCodeRow(title: L10n.string("settings.tools.install_path"), value: MuseTermCLIInstaller.installPath)
                SettingsCodeRow(title: L10n.string("settings.tools.state_path"), value: MuseTermCLIInstaller.supportPath)
            }

            HStack(spacing: 10) {
                Button {
                    installCLI()
                } label: {
                    Label(L10n.string("settings.tools.install_cli"), systemImage: "arrow.down.circle")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    let didCopy = NSPasteboard.general.setString(
                        MuseTermCLIInstaller.installPath,
                        forType: .string
                    )
                    cliInstallMessage = didCopy
                        ? L10n.format("settings.tools.copy_path_success", MuseTermCLIInstaller.installPath)
                        : L10n.string("settings.tools.copy_path_failed")
                } label: {
                    Label(L10n.string("settings.tools.copy_path"), systemImage: "doc.on.doc")
                }
            }

            if !cliInstallMessage.isEmpty {
                Text(cliInstallMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .padding(.vertical, 4)

            Text(L10n.string("settings.tools.commands"))
                .font(.subheadline.weight(.semibold))
            SettingsCodeBlock(text: L10n.string("settings.tools.command_examples"))

            Text(L10n.string("settings.tools.mcp"))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            SettingsCodeBlock(text: L10n.string("settings.tools.mcp_config"))

            Text(L10n.string("ai_control.archive_description"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                do {
                    try FileManager.default.createDirectory(at: TerminalAIArchive.directory,
                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    NSWorkspace.shared.open(TerminalAIArchive.directory)
                } catch {
                    cliInstallMessage = error.localizedDescription
                }
            } label: {
                Label(L10n.string("ai_control.open_archives"), systemImage: "folder")
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(L10n.string("settings.tools.applescript_input"), isOn: $preferences.appleScriptInputEnabled)
            Text(L10n.string("settings.tools.applescript_input_desc"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.string("settings.tools.applescript"))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            SettingsCodeBlock(text: L10n.string("settings.tools.applescript_examples"))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let installed = MuseTermCLIInstaller.isInstalled()
        Label(
            installed ? L10n.string("settings.tools.installed") : L10n.string("settings.tools.not_installed"),
            systemImage: installed ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(installed ? preferences.skin.accent : .secondary)
    }

    private func installCLI() {
        do {
            try MuseTermCLIInstaller.install()
            cliInstallMessage = L10n.format("settings.tools.install_success", MuseTermCLIInstaller.installPath)
        } catch {
            cliInstallMessage = L10n.format("settings.tools.install_failed", error.localizedDescription)
        }
    }

    private func pairBuiltInToolClient() {
        guard TerminalToolAccess.pair() else {
            toolBridgeAccessMessage = L10n.string("settings.tools.client_pair_failed")
            return
        }
        isBuiltInToolClientPaired = true
        toolBridgeAccessMessage = L10n.string("settings.tools.client_pair_success")
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("profile.section"))
                    .font(.headline)
                Spacer()
                Button {
                    editingProfile = TerminalProfile()
                } label: {
                    Label(L10n.string("profile.add"), systemImage: "plus")
                }
            }

            Text(L10n.string("settings.profiles.summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(profileStore.profiles) { profile in
                    settingsProfileRow(profile)
                }
            }
        }
    }

    private func settingsProfileRow(_ profile: TerminalProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.isDefault ? "star.fill" : "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(profile.isDefault ? .yellow : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(settingsProfileSubtitle(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                profileStore.setDefault(profile)
            } label: {
                Text(L10n.string("profile.set_default"))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(profile.isDefault)

            Button {
                editingProfile = profile
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("profile.edit"))

            Button(role: .destructive) {
                profileStore.delete(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(profile.isDefault)
            .help(L10n.string("profile.delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(preferences.skin.controlFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func settingsProfileSubtitle(_ profile: TerminalProfile) -> String {
        let shell = L10n.string(profile.shell.titleKey)
        let prompt = L10n.string(profile.promptStyle.titleKey)
        return "\(shell) · \(prompt)"
    }

    @ViewBuilder
    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.top, 12)
                .padding(.horizontal, 2)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private enum SettingsTab: CaseIterable, Identifiable {
    case appearance
    case appIcon
    case typography
    case glass
    case floatingPanel
    case behavior
    case sidebar
    case profiles
    case notifications
    case ai
    case tools

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .appearance: return "settings.tab.appearance"
        case .appIcon: return "settings.tab.app_icon"
        case .typography: return "settings.tab.typography"
        case .glass: return "settings.tab.glass"
        case .floatingPanel: return "settings.tab.floating_panel"
        case .behavior: return "settings.tab.behavior"
        case .sidebar: return "settings.tab.sidebar"
        case .profiles: return "settings.tab.profiles"
        case .notifications: return "settings.tab.notifications"
        case .ai: return "settings.tab.ai"
        case .tools: return "settings.tab.tools"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .appIcon: return "app"
        case .typography: return "textformat"
        case .glass: return "square.on.square.dashed"
        case .floatingPanel: return "macwindow.on.rectangle"
        case .behavior: return "keyboard"
        case .sidebar: return "sidebar.left"
        case .profiles: return "person.crop.rectangle.stack"
        case .notifications: return "bell.badge"
        case .ai: return "sparkles"
        case .tools: return "hammer"
        }
    }
}

private enum SettingsGroup: CaseIterable, Identifiable {
    case appearance
    case terminal
    case connections
    case notifications
    case intelligence
    case automation

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .appearance: return "settings.group.appearance"
        case .terminal: return "settings.group.terminal"
        case .connections: return "settings.group.connections"
        case .notifications: return "settings.group.notifications"
        case .intelligence: return "settings.group.intelligence"
        case .automation: return "settings.group.automation"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .appearance:
            return [.appearance, .appIcon, .typography, .glass, .floatingPanel]
        case .terminal:
            return [.behavior, .sidebar]
        case .connections:
            return [.profiles]
        case .notifications:
            return [.notifications]
        case .intelligence:
            return [.ai]
        case .automation:
            return [.tools]
        }
    }

    func filteredTabs(matching query: String) -> [SettingsTab] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return tabs }

        let groupTitle = L10n.string(titleKey)
        if groupTitle.localizedCaseInsensitiveContains(trimmedQuery) {
            return tabs
        }
        return tabs.filter {
            L10n.string($0.titleKey).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}

private struct AIProviderChoiceView: View {
    let provider: AIProviderKind
    let isSelected: Bool
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(skin.accent)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(skin.accent)
                }
            }
            Text(provider.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(provider.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(isSelected ? skin.selectionFill : skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
        )
    }

    private var iconName: String {
        switch provider {
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "text.alignleft"
        case .google: return "sparkle.magnifyingglass"
        case .azureOpenAI: return "cloud"
        case .openRouter: return "arrow.triangle.branch"
        case .someIM: return "globe.asia.australia"
        case .ollama: return "desktopcomputer"
        case .llamaServer: return "server.rack"
        case .magpie: return "bird"
        case .custom: return "slider.horizontal.3"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Binding var searchQuery: String
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(SettingsGroup.allCases) { group in
                        let tabs = group.filteredTabs(matching: searchQuery)
                        if !tabs.isEmpty {
                            settingsGroup(group, tabs: tabs)
                        }
                    }

                    if hasNoResults {
                        Text(L10n.string("settings.search.no_results"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                }
            }
        }
        .frame(width: 210, alignment: .topLeading)
        .onChange(of: searchQuery) { newQuery in
            let matches = SettingsGroup.allCases.flatMap {
                $0.filteredTabs(matching: newQuery)
            }
            guard !matches.isEmpty, !matches.contains(selection) else { return }
            selection = matches[0]
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.string("settings.search.placeholder"), text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("action.clear"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        }
    }

    private var hasNoResults: Bool {
        SettingsGroup.allCases.allSatisfy {
            $0.filteredTabs(matching: searchQuery).isEmpty
        }
    }

    @ViewBuilder
    private func settingsGroup(_ group: SettingsGroup, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(group.titleKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)

            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(L10n.string(tab.titleKey), systemImage: tab.systemImage)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(selection == tab ? skin.accent : .primary)
                .background(selection == tab ? skin.selectionFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help(L10n.string(tab.titleKey))
            }
        }
    }
}

private struct AIProviderSettingsSection: View {
    @ObservedObject var preferences: TerminalPreferences
    @Binding var apiKeyDraft: String
    @Binding var statusMessage: String
    let onSaveAPIKey: () -> Bool
    @State private var modelCandidates: [String] = []
    @State private var modelDiscoveryMessage = ""
    @State private var isLoadingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("settings.ai"))
                .font(.headline)
            Text(L10n.string("settings.ai.summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            providerGrid
            customNameField
            connectionFields
            modelDiscoveryPanel
            apiKeyControls
            statusText

            Text(L10n.string("settings.ai.privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(AIProviderKind.allCases) { provider in
                Button {
                    preferences.aiProvider = provider
                    statusMessage = ""
                    refreshModelCandidates(clearExisting: true)
                } label: {
                    AIProviderChoiceView(
                        provider: provider,
                        isSelected: preferences.aiProvider == provider,
                        skin: preferences.skin
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            refreshModelCandidates(clearExisting: false)
        }
        .onChange(of: preferences.aiProvider) { _ in
            refreshModelCandidates(clearExisting: true)
        }
        .onChange(of: preferences.aiBaseURL) { _ in
            refreshModelCandidates(clearExisting: true)
        }
    }

    @ViewBuilder
    private var customNameField: some View {
        if preferences.aiProvider == .custom {
            SettingsTextFieldRow(
                title: L10n.string("settings.ai.custom_name"),
                text: $preferences.aiCustomProviderName,
                placeholder: L10n.string("settings.ai.custom_name.placeholder")
            )
        }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            baseURLPresetPicker
            SettingsTextFieldRow(
                title: L10n.string("settings.ai.base_url"),
                text: $preferences.aiBaseURL,
                placeholder: preferences.aiProvider.defaultBaseURL
            )

            SettingsTextFieldRow(
                title: L10n.string("settings.ai.model"),
                text: $preferences.aiModel,
                placeholder: preferences.aiProvider.defaultModel
            )
        }
    }

    @ViewBuilder
    private var baseURLPresetPicker: some View {
        let presets = preferences.aiProvider.baseURLPresets
        if !presets.isEmpty {
            HStack {
                Text(L10n.string("settings.ai.base_url_preset"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker(
                    L10n.string("settings.ai.base_url_preset"),
                    selection: $preferences.aiBaseURL
                ) {
                    ForEach(presets) { preset in
                        Text(preset.title).tag(preset.url)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
        }
    }

    @ViewBuilder
    private var modelDiscoveryPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(L10n.string("settings.ai.models"), systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refreshModelCandidates(clearExisting: true, force: true)
                } label: {
                    Label(
                        isLoadingModels ? L10n.string("settings.ai.models.loading") : L10n.string("settings.ai.models.refresh"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(isLoadingModels || preferences.aiProvider == .azureOpenAI)
            }

            if isLoadingModels {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.65)
                    Text(L10n.string("settings.ai.models.loading"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !modelCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(modelCandidates, id: \.self) { model in
                            Button {
                                preferences.aiModel = model
                                statusMessage = L10n.format("settings.ai.models.selected", model)
                            } label: {
                                Text(model)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        preferences.aiModel == model
                                            ? preferences.skin.selectionFill
                                            : preferences.skin.controlFill
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(
                                                preferences.aiModel == model
                                                    ? preferences.skin.accent.opacity(0.5)
                                                    : preferences.skin.hairline,
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            } else if !modelDiscoveryMessage.isEmpty {
                Text(modelDiscoveryMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apiKeyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("settings.ai.api_key"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                apiKeyStatusBadge
            }
            SecureField(apiKeyPlaceholder, text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button {
                    if onSaveAPIKey() {
                        refreshModelCandidates(clearExisting: true, force: true)
                    }
                } label: {
                    Label(L10n.string("settings.ai.api_key.save"), systemImage: "key.fill")
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    preferences.clearAIAPIKey()
                    apiKeyDraft = ""
                    statusMessage = L10n.string("settings.ai.api_key.clear_success")
                    modelCandidates = []
                    modelDiscoveryMessage = ""
                } label: {
                    Label(L10n.string("settings.ai.api_key.clear"), systemImage: "trash")
                }
                .disabled(!preferences.hasAIAPIKey)
            }
        }
    }

    private var apiKeyPlaceholder: String {
        preferences.hasAIAPIKey
            ? L10n.string("settings.ai.api_key.placeholder.saved")
            : L10n.string("settings.ai.api_key.placeholder")
    }

    private var apiKeyStatusBadge: some View {
        Label(
            preferences.hasAIAPIKey ? L10n.string("settings.ai.api_key.saved") : L10n.string("settings.ai.api_key.not_saved"),
            systemImage: preferences.hasAIAPIKey ? "checkmark.circle.fill" : "key"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(preferences.hasAIAPIKey ? preferences.skin.accent : .secondary)
    }

    @ViewBuilder
    private var statusText: some View {
        if !statusMessage.isEmpty {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshModelCandidates(clearExisting: Bool, force: Bool = false) {
        if clearExisting {
            modelCandidates = []
            modelDiscoveryMessage = ""
        }
        guard preferences.aiProvider != .azureOpenAI else {
            modelDiscoveryMessage = L10n.string("settings.ai.models.azure_unavailable")
            return
        }
        let savedKey = preferences.loadAIAPIKey()
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (savedKey.isEmpty && preferences.aiProvider == .magpie ? AIProviderKind.magpieLocalGatewayAPIKey : savedKey)
            : apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferences.aiProvider.isLocalProvider, key.isEmpty {
            if force {
                modelDiscoveryMessage = L10n.string("settings.ai.models.needs_key")
            }
            return
        }
        guard !preferences.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if force {
                modelDiscoveryMessage = L10n.string("settings.ai.models.needs_base_url")
            }
            return
        }
        isLoadingModels = true
        let provider = preferences.aiProvider
        let baseURL = preferences.aiBaseURL
        Task {
            do {
                let models = try await AIModelDiscovery(
                    provider: provider,
                    baseURL: baseURL,
                    apiKey: key
                ).fetch()
                await MainActor.run {
                    guard provider == preferences.aiProvider, baseURL == preferences.aiBaseURL else { return }
                    isLoadingModels = false
                    modelCandidates = models
                    modelDiscoveryMessage = models.isEmpty
                        ? L10n.string("settings.ai.models.empty")
                        : ""
                }
            } catch {
                await MainActor.run {
                    guard provider == preferences.aiProvider, baseURL == preferences.aiBaseURL else { return }
                    isLoadingModels = false
                    modelCandidates = []
                    modelDiscoveryMessage = L10n.format(
                        "settings.ai.models.failed",
                        error.localizedDescription
                    )
                }
            }
        }
    }

}

private struct AppIconChoiceView: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                iconPreview
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(skin.accent)
                }
            }
            Text(choice.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(choice.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(isSelected ? skin.selectionFill : skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let nsImage = choice.nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(skin.controlFill)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct SkinChoiceView: View {
    let skin: TerminalVisualSkin
    let isSelected: Bool

    private var previewBackground: Color {
        Color(nsColor: skin.terminalBackground)
    }

    private var previewForeground: Color {
        Color(nsColor: skin.terminalForeground)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: skin.symbolName)
                    .foregroundStyle(skin.accent)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(skin.accent)
                }
            }
            Text(skin.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(previewForeground)
            Text(skin.summary)
                .font(.caption)
                .foregroundStyle(previewForeground)
                .lineLimit(2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                ForEach(Array(skin.ansiColors.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(height: 9)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background {
            ZStack {
                previewBackground
                if isSelected {
                    skin.selectionFill
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
        )
    }
}

private struct FontFamilyPicker: View {
    let title: String
    @Binding var selection: String

    private var options: [String] {
        let installedFamilies = TerminalFontResolver.installedFamilies
        guard !selection.isEmpty, !installedFamilies.contains(selection) else {
            return installedFamilies
        }
        return [selection] + installedFamilies
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { family in
                    Text(family)
                        .tag(family)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(selection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 有序回退字体编辑器：靠前的字体先被 Core Text 级联命中，
/// 因此中文字体与图标字体可以同时生效，互不挤占。
private struct FallbackFontListEditor: View {
    let title: String
    @Binding var families: [String]

    private var canAddMore: Bool {
        families.count < TerminalFontResolver.maximumFallbackFamilies
            && !availableFamilies(excludingIndex: nil).isEmpty
    }

    /// 排除其他行已占用的字体，避免选重后被去重逻辑悄悄吞掉一行。
    private func availableFamilies(excludingIndex index: Int?) -> [String] {
        var used = Set(families.map { $0.lowercased() })
        if let index, index < families.count {
            used.remove(families[index].lowercased())
        }
        return TerminalFontResolver.installedFamilies.filter { !used.contains($0.lowercased()) }
    }

    private func options(for index: Int) -> [String] {
        let current = families[index]
        var result = availableFamilies(excludingIndex: index)
        if !current.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            result.insert(current, at: 0)
        }
        return result
    }

    private func move(from index: Int, offset: Int) {
        let target = index + offset
        guard families.indices.contains(index), families.indices.contains(target) else { return }
        families.swapAt(index, target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            if families.isEmpty {
                Text(L10n.string("settings.fallback_font.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(families.enumerated()), id: \.element) { index, family in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)

                    Picker(family, selection: familyBinding(at: index)) {
                        ForEach(options(for: index), id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        move(from: index, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help(L10n.string("settings.fallback_font.move_up"))

                    Button {
                        move(from: index, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == families.count - 1)
                    .help(L10n.string("settings.fallback_font.move_down"))

                    Button {
                        guard families.indices.contains(index) else { return }
                        families.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("settings.fallback_font.remove"))
                }
            }

            Button {
                guard let next = availableFamilies(excludingIndex: nil).first else { return }
                families.append(next)
            } label: {
                Label(L10n.string("settings.fallback_font.add"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(!canAddMore)
        }
    }

    private func familyBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { families.indices.contains(index) ? families[index] : "" },
            set: { newValue in
                guard families.indices.contains(index) else { return }
                families[index] = newValue
            }
        )
    }
}

private struct SettingsCodeRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct SettingsCodeBlock: View {
    let text: String
    @State private var copied = false
    @State private var copyResetToken = UUID()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .padding(.trailing, 64)

            Button {
                copyToPasteboard()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    if copied {
                        Text(L10n.string("action.copied"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("action.copy"))
            .accessibilityLabel(L10n.string("action.copy"))
            .padding(4)
        }
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let token = UUID()
        copyResetToken = token
        withAnimation(.easeOut(duration: 0.15)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copyResetToken == token else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                copied = false
            }
        }
    }
}

/// 「拉黑」管理：列出被拉黑的路径与命令，可逐条撤销。直接读写黑名单存储，撤销后广播
/// `.recommendationBlacklistChanged`，运行中的工作区据此重载并刷新最近/常用列表。
private struct RecommendationBlacklistManagerView: View {
    let skin: TerminalVisualSkin
    @State private var paths: [String] = []
    @State private var commands: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("settings.blacklist.title"))
                .font(.caption.weight(.semibold))
            Text(L10n.string("settings.blacklist.help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            group(
                title: L10n.string("settings.blacklist.paths"),
                items: paths,
                empty: L10n.string("settings.blacklist.empty_paths"),
                remove: removePath
            )
            group(
                title: L10n.string("settings.blacklist.commands"),
                items: commands,
                empty: L10n.string("settings.blacklist.empty_commands"),
                remove: removeCommand
            )
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func group(
        title: String,
        items: [String],
        empty: String,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Text(item)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            remove(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("settings.blacklist.remove"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(skin.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private func reload() {
        paths = TerminalQuickPathBlacklistStore.load().sorted()
        commands = LearnedCommandBlacklistStore.load().sorted()
    }

    private func removePath(_ path: String) {
        var set = TerminalQuickPathBlacklistStore.load()
        set.remove(path)
        TerminalQuickPathBlacklistStore.save(set)
        NotificationCenter.default.post(name: .recommendationBlacklistChanged, object: nil)
        reload()
    }

    private func removeCommand(_ command: String) {
        var set = LearnedCommandBlacklistStore.load()
        set.remove(command)
        LearnedCommandBlacklistStore.save(set)
        NotificationCenter.default.post(name: .recommendationBlacklistChanged, object: nil)
        reload()
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var multiplier = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: format, value * multiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
