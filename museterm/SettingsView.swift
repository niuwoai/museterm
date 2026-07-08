import SwiftUI

struct SettingsView: View {
    static let defaultWindowSize = CGSize(width: 720, height: 590)

    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject private var notificationCoordinator = TerminalNotificationCoordinator.shared
    @State private var selectedSettingsTab: SettingsTab = .appearance
    @State private var cliInstallMessage = ""
    @State private var aiAPIKeyDraft = ""
    @State private var aiStatusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            SettingsTabBar(
                selection: $selectedSettingsTab,
                skin: preferences.skin
            )
            settingsPage {
                settingsContent
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
        case .behavior:
            behaviorSection
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
            Text(L10n.string("settings.skin"))
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(TerminalVisualSkin.allCases) { skin in
                    Button {
                        preferences.skin = skin
                    } label: {
                        SkinChoiceView(skin: skin, isSelected: preferences.skin == skin)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(L10n.string("settings.palette"))
                .font(.headline)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TerminalColorPalette.allCases) { palette in
                    Button {
                        preferences.colorPalette = palette
                    } label: {
                        PaletteChoiceView(
                            palette: palette,
                            isSelected: preferences.colorPalette == palette,
                            skin: preferences.skin
                        )
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
            FontSearchPicker(
                title: L10n.string("settings.primary_font"),
                selection: $preferences.fontFamily
            )
            FontSearchPicker(
                title: L10n.string("settings.fallback_font"),
                selection: $preferences.fallbackFontFamily
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
                title: L10n.string("settings.terminal_opacity"),
                value: $preferences.terminalOpacity,
                range: 0.45...1,
                format: "%.0f%%",
                multiplier: 100
            )

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

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("settings.behavior"))
                .font(.headline)
            Toggle(L10n.string("settings.show_tab_list"), isOn: $preferences.showsTabList)
            Toggle(L10n.string("settings.option_as_meta"), isOn: $preferences.optionAsMeta)
            Toggle(L10n.string("settings.mouse_reporting"), isOn: $preferences.mouseReporting)
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
        }
    }

    private var aiSection: some View {
        AIProviderSettingsSection(
            preferences: preferences,
            apiKeyDraft: $aiAPIKeyDraft,
            statusMessage: $aiStatusMessage
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
                    NSPasteboard.general.setString(MuseTermCLIInstaller.installPath, forType: .string)
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
    case behavior
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
        case .behavior: return "settings.tab.behavior"
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
        case .behavior: return "keyboard"
        case .notifications: return "bell.badge"
        case .ai: return "sparkles"
        case .tools: return "hammer"
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
        case .custom: return "slider.horizontal.3"
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    let skin: TerminalVisualSkin

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(L10n.string(tab.titleKey), systemImage: tab.systemImage)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        // 让整块胶囊（含内边距/留白）都可点击，而非仅文字本身。
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(selection == tab ? skin.accent : .secondary)
                .background(selection == tab ? skin.selectionFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help(L10n.string(tab.titleKey))
            }
        }
        .padding(4)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AIProviderSettingsSection: View {
    @ObservedObject var preferences: TerminalPreferences
    @Binding var apiKeyDraft: String
    @Binding var statusMessage: String
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
                    if preferences.saveAIAPIKey(apiKeyDraft) {
                        apiKeyDraft = ""
                        statusMessage = L10n.string("settings.ai.api_key.save_success")
                        refreshModelCandidates(clearExisting: true, force: true)
                    } else {
                        statusMessage = L10n.string("settings.ai.api_key.save_failed")
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
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? preferences.loadAIAPIKey()
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
            Text(skin.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(isSelected ? skin.selectionFill : skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
        )
    }
}

private struct FontSearchPicker: View {
    let title: String
    @Binding var selection: String
    @State private var query = ""

    private var families: [String] {
        let all = TerminalFontResolver.installedFamilies
        guard !query.isEmpty else { return Array(all.prefix(24)) }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(24).map(\.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(selection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField(selection, text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(families, id: \.self) { family in
                        Button {
                            selection = family
                            query = ""
                        } label: {
                            HStack {
                                Text(family)
                                    .font(.custom(family, size: 12))
                                    .lineLimit(1)
                                Spacer()
                                if selection == family {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 96)
        }
    }
}

private struct PaletteChoiceView: View {
    let palette: TerminalColorPalette
    let isSelected: Bool
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(palette.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(skin.accent)
                }
            }
            Text(palette.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                ForEach(Array(palette.nsColors.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(height: 9)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(isSelected ? skin.selectionFill : skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
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
