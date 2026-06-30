import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            TabView {
                settingsPage {
                    skinSection
                }
                .tabItem {
                    Label(L10n.string("settings.tab.appearance"), systemImage: "paintpalette")
                }

                settingsPage {
                    appIconSection
                }
                .tabItem {
                    Label(L10n.string("settings.tab.app_icon"), systemImage: "app")
                }

                settingsPage {
                    fontSection
                }
                .tabItem {
                    Label(L10n.string("settings.tab.typography"), systemImage: "textformat")
                }

                settingsPage {
                    glassSection
                }
                .tabItem {
                    Label(L10n.string("settings.tab.glass"), systemImage: "square.on.square.dashed")
                }

                settingsPage {
                    behaviorSection
                }
                .tabItem {
                    Label(L10n.string("settings.tab.behavior"), systemImage: "keyboard")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 560, height: 460)
        .background(preferences.skin.panelFill)
        .tint(preferences.skin.accent)
        .preferredColorScheme(preferences.skin.preferredColorScheme)
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
            Toggle(L10n.string("settings.option_as_meta"), isOn: $preferences.optionAsMeta)
            Toggle(L10n.string("settings.mouse_reporting"), isOn: $preferences.mouseReporting)
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
