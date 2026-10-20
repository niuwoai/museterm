import AppKit
import SwiftUI

/// 单个皮肤的完整配色规格。融合后每个皮肤自带一份最匹配的 ANSI 16 色，
/// 不再依赖独立的 ANSI 配色方案。
struct TerminalSkinSpec {
    let symbolName: String
    let isDark: Bool
    let accent: Color
    let secondaryAccent: Color
    /// 窗口背景渐变（topLeading → bottomTrailing），3 个色标。
    let windowStops: [Color]
    /// 侧栏背景渐变（top → bottom），2 个已带透明度的色标。
    let sidebarStops: [Color]
    let panelFill: Color
    let controlFill: Color
    /// selectionFill = accent.opacity(selectionOpacity)
    let selectionOpacity: Double
    let tabSelectionFill: Color
    /// tabSelectionBorder = accent.opacity(tabSelectionBorderOpacity)
    let tabSelectionBorderOpacity: Double
    let hoverFill: Color
    let hairline: Color
    let foregroundHex: Int
    let backgroundHex: Int
    let caretHex: Int
    /// ANSI 16 色（0-7 普通 + 8-15 亮色）。
    let ansi: [Int]
}

enum TerminalVisualSkin: String, CaseIterable, Identifiable {
    // 浅色系
    case seaSalt
    case mist
    case ink
    case sakura
    case linen
    case sky
    case matcha
    case sand
    // 深色系
    case midnight
    case aurora
    case ember
    case dusk
    case polar
    case carbon
    case abyss
    case garnet
    // 经典开源配色；稳定 rawValue 用于保存用户偏好。
    case catppuccinLatte
    case catppuccinFrappe
    case catppuccinMacchiato
    case catppuccinMocha
    case tokyoDay
    case tokyoNight
    case tokyoStorm
    case tokyoMoon
    case rosePine
    case roseMoon
    case roseDawn
    case gruvboxDark
    case gruvboxLight
    case everforestDark
    case everforestLight
    case kanagawaWave
    case kanagawaDragon
    case ayuDark
    case ayuLight
    case ayuMirage
    case monokai
    case solarizedDark
    case tomorrow
    case tomorrowNight

    var id: String { rawValue }

    var name: String {
        L10n.string("skin.\(rawValue).name")
    }

    var summary: String {
        L10n.string("skin.\(rawValue).summary")
    }

    var symbolName: String { spec.symbolName }

    var preferredColorScheme: ColorScheme? { spec.isDark ? .dark : .light }

    var accent: Color { spec.accent }

    var secondaryAccent: Color { spec.secondaryAccent }

    var windowBackground: LinearGradient {
        LinearGradient(colors: spec.windowStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var sidebarBackground: LinearGradient {
        LinearGradient(colors: spec.sidebarStops, startPoint: .top, endPoint: .bottom)
    }

    var panelFill: Color { spec.panelFill }

    var controlFill: Color { spec.controlFill }

    var selectionFill: Color { spec.accent.opacity(spec.selectionOpacity) }

    var tabSelectionFill: Color { spec.tabSelectionFill }

    var tabSelectionBorder: Color { spec.accent.opacity(spec.tabSelectionBorderOpacity) }

    var hoverFill: Color { spec.hoverFill }

    var hairline: Color { spec.hairline }

    var terminalForeground: NSColor { NSColor(hex: spec.foregroundHex) }

    var terminalBackground: NSColor { NSColor(hex: spec.backgroundHex) }

    var caret: NSColor { NSColor(hex: spec.caretHex) }

    func terminalSelectionBackground(opacity: CGFloat) -> NSColor {
        let highlightFraction: CGFloat = 0.22
        // SwiftTerm replaces the cell background with this color instead of overlaying it.
        let highlighted = terminalBackground.blended(withFraction: highlightFraction, of: caret)
            ?? terminalBackground
        return highlighted.withAlphaComponent(opacity)
    }

    /// ANSI 16 色（用于设置界面的色块预览）。
    var ansiColors: [NSColor] { spec.ansi.map { NSColor(hex: $0) } }

    /// ANSI 16 色的原始十六进制值（供终端渲染扩展使用）。
    var ansiHexColors: [Int] { spec.ansi }

    // swiftlint:disable:next function_body_length
    var spec: TerminalSkinSpec {
        switch self {
        case .catppuccinLatte:
            return Self.classicCatppuccinLatte
        case .catppuccinFrappe:
            return Self.classicCatppuccinFrappe
        case .catppuccinMacchiato:
            return Self.classicCatppuccinMacchiato
        case .catppuccinMocha:
            return Self.classicCatppuccinMocha
        case .tokyoDay:
            return Self.classicTokyoDay
        case .tokyoNight:
            return Self.classicTokyoNight
        case .tokyoStorm:
            return Self.classicTokyoStorm
        case .tokyoMoon:
            return Self.classicTokyoMoon
        case .rosePine:
            return Self.classicRosePine
        case .roseMoon:
            return Self.classicRoseMoon
        case .roseDawn:
            return Self.classicRoseDawn
        case .gruvboxDark:
            return Self.classicGruvboxDark
        case .gruvboxLight:
            return Self.classicGruvboxLight
        case .everforestDark:
            return Self.classicEverforestDark
        case .everforestLight:
            return Self.classicEverforestLight
        case .kanagawaWave:
            return Self.classicKanagawaWave
        case .kanagawaDragon:
            return Self.classicKanagawaDragon
        case .ayuDark:
            return Self.classicAyuDark
        case .ayuLight:
            return Self.classicAyuLight
        case .ayuMirage:
            return Self.classicAyuMirage
        case .monokai:
            return Self.classicMonokai
        case .solarizedDark:
            return Self.classicSolarizedDark
        case .tomorrow:
            return Self.classicTomorrow
        case .tomorrowNight:
            return Self.classicTomorrowNight
        case .seaSalt:
            return TerminalSkinSpec(
                symbolName: "water.waves",
                isDark: false,
                accent: Color(red: 0.17, green: 0.52, blue: 0.64),
                secondaryAccent: Color(red: 0.86, green: 0.57, blue: 0.36),
                windowStops: [
                    Color(red: 0.91, green: 0.97, blue: 0.98),
                    Color(red: 0.95, green: 0.96, blue: 0.90),
                    Color(red: 0.86, green: 0.94, blue: 0.95)
                ],
                sidebarStops: [
                    Color(red: 0.86, green: 0.95, blue: 0.97).opacity(0.94),
                    Color(red: 0.98, green: 0.94, blue: 0.86).opacity(0.78)
                ],
                panelFill: Color.white.opacity(0.58),
                controlFill: Color(red: 0.98, green: 0.99, blue: 0.96).opacity(0.76),
                selectionOpacity: 0.16,
                tabSelectionFill: Color(red: 0.78, green: 0.93, blue: 0.91).opacity(0.74),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.86, green: 0.57, blue: 0.36).opacity(0.10),
                hairline: Color(red: 0.22, green: 0.46, blue: 0.52).opacity(0.17),
                foregroundHex: 0x183640,
                backgroundHex: 0xE8F4F3,
                caretHex: 0x2B85A3,
                ansi: [
                    0x183640, 0xC0392B, 0x2E8B57, 0xB58A00,
                    0x2565AE, 0x9C4DA0, 0x0E7C8C, 0xD2E0DF,
                    0x4A6670, 0xE0554A, 0x36A76A, 0xCBA31E,
                    0x3B82C4, 0xB566B8, 0x1FA0AE, 0xE8F4F3
                ]
            )
        case .mist:
            return TerminalSkinSpec(
                symbolName: "leaf",
                isDark: false,
                accent: Color(red: 0.23, green: 0.48, blue: 0.42),
                secondaryAccent: Color(red: 0.77, green: 0.46, blue: 0.35),
                windowStops: [
                    Color(red: 0.94, green: 0.98, blue: 0.95),
                    Color(red: 0.98, green: 0.95, blue: 0.91),
                    Color(red: 0.90, green: 0.96, blue: 0.98)
                ],
                sidebarStops: [
                    Color(red: 0.90, green: 0.97, blue: 0.92).opacity(0.92),
                    Color(red: 0.98, green: 0.93, blue: 0.88).opacity(0.82)
                ],
                panelFill: Color.white.opacity(0.54),
                controlFill: Color.white.opacity(0.72),
                selectionOpacity: 0.17,
                tabSelectionFill: Color(red: 0.79, green: 0.92, blue: 0.84).opacity(0.72),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.77, green: 0.46, blue: 0.35).opacity(0.10),
                hairline: Color(red: 0.28, green: 0.43, blue: 0.36).opacity(0.18),
                foregroundHex: 0x17382F,
                backgroundHex: 0xEAF5EC,
                caretHex: 0x3B7A6B,
                ansi: [
                    0x17382F, 0xB0472B, 0x4E8A3E, 0xA88400,
                    0x3A76A0, 0x9C5A8C, 0x2A8574, 0xD6E2D8,
                    0x557064, 0xD35F3E, 0x63A64E, 0xC29A1E,
                    0x4E86B8, 0xB56F9E, 0x36A28C, 0xEAF5EC
                ]
            )
        case .ink:
            return TerminalSkinSpec(
                symbolName: "paintbrush.pointed",
                isDark: false,
                accent: Color(red: 0.18, green: 0.25, blue: 0.31),
                secondaryAccent: Color(red: 0.58, green: 0.43, blue: 0.23),
                windowStops: [
                    Color(red: 0.93, green: 0.92, blue: 0.88),
                    Color(red: 0.83, green: 0.86, blue: 0.84),
                    Color(red: 0.96, green: 0.94, blue: 0.89)
                ],
                sidebarStops: [
                    Color(red: 0.88, green: 0.88, blue: 0.84).opacity(0.95),
                    Color(red: 0.76, green: 0.80, blue: 0.78).opacity(0.85)
                ],
                panelFill: Color(red: 0.98, green: 0.96, blue: 0.90).opacity(0.48),
                controlFill: Color(red: 0.97, green: 0.95, blue: 0.88).opacity(0.74),
                selectionOpacity: 0.15,
                tabSelectionFill: Color(red: 0.91, green: 0.88, blue: 0.77).opacity(0.70),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color.black.opacity(0.07),
                hairline: Color(red: 0.22, green: 0.25, blue: 0.24).opacity(0.20),
                foregroundHex: 0x243238,
                backgroundHex: 0xE7E3D7,
                caretHex: 0x2E404F,
                ansi: [
                    0x243238, 0xB83A2E, 0x4E7A32, 0xA07E00,
                    0x35618C, 0x8E4B84, 0x2A7D74, 0xCFC9B8,
                    0x5A5548, 0xD1533E, 0x63924A, 0xBE961E,
                    0x4A7BA8, 0xA9639E, 0x369A8E, 0xF3EEDD
                ]
            )
        case .sakura:
            return TerminalSkinSpec(
                symbolName: "sparkles",
                isDark: false,
                accent: Color(red: 0.85, green: 0.35, blue: 0.52),
                secondaryAccent: Color(red: 0.55, green: 0.45, blue: 0.75),
                windowStops: [
                    Color(red: 0.99, green: 0.94, blue: 0.96),
                    Color(red: 0.98, green: 0.93, blue: 0.95),
                    Color(red: 0.96, green: 0.90, blue: 0.94)
                ],
                sidebarStops: [
                    Color(red: 0.99, green: 0.92, blue: 0.95).opacity(0.94),
                    Color(red: 0.97, green: 0.94, blue: 0.98).opacity(0.80)
                ],
                panelFill: Color.white.opacity(0.58),
                controlFill: Color(red: 1.00, green: 0.97, blue: 0.98).opacity(0.78),
                selectionOpacity: 0.16,
                tabSelectionFill: Color(red: 0.98, green: 0.86, blue: 0.91).opacity(0.74),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.55, green: 0.45, blue: 0.75).opacity(0.10),
                hairline: Color(red: 0.72, green: 0.40, blue: 0.52).opacity(0.18),
                foregroundHex: 0x4A2C38,
                backgroundHex: 0xFBF0F4,
                caretHex: 0xD35C86,
                ansi: [
                    0x4A2C38, 0xC0392B, 0x4E8A4A, 0xB8860B,
                    0x3A72B0, 0xB5388A, 0x2A8E9A, 0xE9DCE2,
                    0x8A6B76, 0xE0574A, 0x5EA65A, 0xC9A227,
                    0x4E86C4, 0xCE4F9E, 0x38A2AE, 0xFBF0F4
                ]
            )
        case .linen:
            return TerminalSkinSpec(
                symbolName: "book.closed",
                isDark: false,
                accent: Color(red: 0.20, green: 0.40, blue: 0.75),
                secondaryAccent: Color(red: 0.70, green: 0.35, blue: 0.20),
                windowStops: [
                    Color(red: 0.98, green: 0.97, blue: 0.94),
                    Color(red: 0.97, green: 0.96, blue: 0.93),
                    Color(red: 0.95, green: 0.94, blue: 0.90)
                ],
                sidebarStops: [
                    Color(red: 0.97, green: 0.96, blue: 0.93).opacity(0.95),
                    Color(red: 0.94, green: 0.93, blue: 0.89).opacity(0.82)
                ],
                panelFill: Color.white.opacity(0.60),
                controlFill: Color(red: 0.99, green: 0.98, blue: 0.96).opacity(0.80),
                selectionOpacity: 0.15,
                tabSelectionFill: Color(red: 0.90, green: 0.92, blue: 0.97).opacity(0.72),
                tabSelectionBorderOpacity: 0.26,
                hoverFill: Color.black.opacity(0.06),
                hairline: Color(red: 0.30, green: 0.30, blue: 0.28).opacity(0.16),
                foregroundHex: 0x24292F,
                backgroundHex: 0xFBFAF6,
                caretHex: 0x2F63C4,
                ansi: [
                    0x24292E, 0xD73A49, 0x22863A, 0xB08800,
                    0x0366D6, 0x6F42C1, 0x1B7C83, 0xD1D5DA,
                    0x6A737D, 0xCB2431, 0x28A745, 0xDBAB09,
                    0x2188FF, 0x8A63D2, 0x3192AA, 0xFBFAF6
                ]
            )
        case .sky:
            return TerminalSkinSpec(
                symbolName: "sun.max",
                isDark: false,
                accent: Color(red: 0.10, green: 0.50, blue: 0.80),
                secondaryAccent: Color(red: 0.95, green: 0.60, blue: 0.20),
                windowStops: [
                    Color(red: 0.90, green: 0.95, blue: 0.99),
                    Color(red: 0.93, green: 0.97, blue: 1.00),
                    Color(red: 0.85, green: 0.92, blue: 0.98)
                ],
                sidebarStops: [
                    Color(red: 0.88, green: 0.94, blue: 0.99).opacity(0.94),
                    Color(red: 0.95, green: 0.97, blue: 1.00).opacity(0.80)
                ],
                panelFill: Color.white.opacity(0.56),
                controlFill: Color(red: 0.96, green: 0.98, blue: 1.00).opacity(0.78),
                selectionOpacity: 0.16,
                tabSelectionFill: Color(red: 0.80, green: 0.90, blue: 0.98).opacity(0.74),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.95, green: 0.60, blue: 0.20).opacity(0.10),
                hairline: Color(red: 0.20, green: 0.45, blue: 0.65).opacity(0.18),
                foregroundHex: 0x18344A,
                backgroundHex: 0xEAF3FB,
                caretHex: 0x1E7BC4,
                ansi: [
                    0x18344A, 0xC63C3C, 0x2E8B57, 0xB58A00,
                    0x1E6FB8, 0x9B4DC4, 0x0E8FA0, 0xDCE6EE,
                    0x5A7386, 0xE05555, 0x36A76A, 0xCBA31E,
                    0x3B8FD6, 0xB566D8, 0x22A6B8, 0xEAF3FB
                ]
            )
        case .matcha:
            return TerminalSkinSpec(
                symbolName: "cup.and.saucer",
                isDark: false,
                accent: Color(red: 0.30, green: 0.55, blue: 0.25),
                secondaryAccent: Color(red: 0.75, green: 0.55, blue: 0.20),
                windowStops: [
                    Color(red: 0.95, green: 0.97, blue: 0.90),
                    Color(red: 0.97, green: 0.98, blue: 0.92),
                    Color(red: 0.92, green: 0.95, blue: 0.86)
                ],
                sidebarStops: [
                    Color(red: 0.93, green: 0.96, blue: 0.88).opacity(0.94),
                    Color(red: 0.97, green: 0.97, blue: 0.90).opacity(0.80)
                ],
                panelFill: Color.white.opacity(0.55),
                controlFill: Color(red: 0.97, green: 0.98, blue: 0.93).opacity(0.78),
                selectionOpacity: 0.17,
                tabSelectionFill: Color(red: 0.85, green: 0.92, blue: 0.78).opacity(0.72),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.75, green: 0.55, blue: 0.20).opacity(0.10),
                hairline: Color(red: 0.35, green: 0.45, blue: 0.25).opacity(0.18),
                foregroundHex: 0x2C3A22,
                backgroundHex: 0xF0F4E6,
                caretHex: 0x5C8A3C,
                ansi: [
                    0x2C3A22, 0xB0472B, 0x4E7A2E, 0xA88400,
                    0x3A72A0, 0x9C5A8C, 0x2A8574, 0xDEE3D2,
                    0x66735A, 0xD35F3E, 0x639A44, 0xC29A1E,
                    0x4E86B8, 0xB56F9E, 0x36A28C, 0xF0F4E6
                ]
            )
        case .sand:
            return TerminalSkinSpec(
                symbolName: "sun.horizon",
                isDark: false,
                accent: Color(red: 0.72, green: 0.40, blue: 0.15),
                secondaryAccent: Color(red: 0.15, green: 0.55, blue: 0.55),
                windowStops: [
                    Color(red: 0.99, green: 0.96, blue: 0.89),
                    Color(red: 0.98, green: 0.95, blue: 0.87),
                    Color(red: 0.97, green: 0.93, blue: 0.84)
                ],
                sidebarStops: [
                    Color(red: 0.98, green: 0.95, blue: 0.87).opacity(0.94),
                    Color(red: 0.96, green: 0.92, blue: 0.83).opacity(0.82)
                ],
                panelFill: Color.white.opacity(0.50),
                controlFill: Color(red: 0.99, green: 0.96, blue: 0.89).opacity(0.78),
                selectionOpacity: 0.16,
                tabSelectionFill: Color(red: 0.95, green: 0.88, blue: 0.74).opacity(0.72),
                tabSelectionBorderOpacity: 0.28,
                hoverFill: Color(red: 0.15, green: 0.55, blue: 0.55).opacity(0.10),
                hairline: Color(red: 0.55, green: 0.42, blue: 0.20).opacity(0.18),
                foregroundHex: 0x586E75,
                backgroundHex: 0xFDF6E3,
                caretHex: 0xCB4B16,
                ansi: [
                    0x073642, 0xDC322F, 0x859900, 0xB58900,
                    0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                    0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                    0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
                ]
            )
        case .midnight:
            return TerminalSkinSpec(
                symbolName: "moon.stars",
                isDark: true,
                accent: Color(red: 0.42, green: 0.52, blue: 0.96),
                secondaryAccent: Color(red: 0.50, green: 0.68, blue: 1.00),
                windowStops: [
                    Color(red: 0.08, green: 0.10, blue: 0.17),
                    Color(red: 0.11, green: 0.13, blue: 0.23),
                    Color(red: 0.17, green: 0.18, blue: 0.29)
                ],
                sidebarStops: [
                    Color(red: 0.07, green: 0.09, blue: 0.16).opacity(0.96),
                    Color(red: 0.14, green: 0.15, blue: 0.24).opacity(0.92)
                ],
                panelFill: Color(red: 0.10, green: 0.12, blue: 0.21).opacity(0.88),
                controlFill: Color(red: 0.14, green: 0.16, blue: 0.27).opacity(0.84),
                selectionOpacity: 0.24,
                tabSelectionFill: Color(red: 0.42, green: 0.52, blue: 0.96).opacity(0.30),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.50, green: 0.68, blue: 1.00).opacity(0.13),
                hairline: Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.24),
                foregroundHex: 0xD9E6FF,
                backgroundHex: 0x121725,
                caretHex: 0x7FAAFF,
                ansi: [
                    0x1B2233, 0xE06C75, 0x7FD88F, 0xE5C07B,
                    0x7FAAFF, 0xC599F0, 0x56C7D6, 0xC8D3F0,
                    0x3B4568, 0xF07C86, 0x92E5A2, 0xF0CE8E,
                    0x9CC0FF, 0xD4ADF5, 0x6FD9E6, 0xE6ECFF
                ]
            )
        case .aurora:
            return TerminalSkinSpec(
                symbolName: "waveform.path.ecg",
                isDark: true,
                accent: Color(red: 0.20, green: 0.78, blue: 0.54),
                secondaryAccent: Color(red: 0.22, green: 0.63, blue: 0.88),
                windowStops: [
                    Color(red: 0.04, green: 0.16, blue: 0.13),
                    Color(red: 0.08, green: 0.27, blue: 0.20),
                    Color(red: 0.04, green: 0.11, blue: 0.17)
                ],
                sidebarStops: [
                    Color(red: 0.03, green: 0.15, blue: 0.12).opacity(0.96),
                    Color(red: 0.05, green: 0.19, blue: 0.24).opacity(0.92)
                ],
                panelFill: Color(red: 0.05, green: 0.18, blue: 0.16).opacity(0.86),
                controlFill: Color(red: 0.08, green: 0.23, blue: 0.20).opacity(0.84),
                selectionOpacity: 0.20,
                tabSelectionFill: Color(red: 0.20, green: 0.78, blue: 0.54).opacity(0.26),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.20, green: 0.78, blue: 0.54).opacity(0.12),
                hairline: Color(red: 0.25, green: 0.86, blue: 0.62).opacity(0.24),
                foregroundHex: 0xD8F7EA,
                backgroundHex: 0x081F1A,
                caretHex: 0x33C789,
                ansi: [
                    0x0C2620, 0xE0685E, 0x33C789, 0xD8C15A,
                    0x4F9FD0, 0xB07BD6, 0x3AC7B0, 0xC2E6DB,
                    0x2E5A4E, 0xF0827A, 0x52E0A0, 0xEDD474,
                    0x6FB8E0, 0xC694E8, 0x5AE0CC, 0xD8F7EA
                ]
            )
        case .ember:
            return TerminalSkinSpec(
                symbolName: "flame",
                isDark: true,
                accent: Color(red: 0.96, green: 0.49, blue: 0.14),
                secondaryAccent: Color(red: 1.00, green: 0.66, blue: 0.18),
                windowStops: [
                    Color(red: 0.15, green: 0.12, blue: 0.10),
                    Color(red: 0.22, green: 0.17, blue: 0.13),
                    Color(red: 0.10, green: 0.09, blue: 0.08)
                ],
                sidebarStops: [
                    Color(red: 0.18, green: 0.14, blue: 0.11).opacity(0.96),
                    Color(red: 0.10, green: 0.08, blue: 0.07).opacity(0.92)
                ],
                panelFill: Color(red: 0.18, green: 0.14, blue: 0.11).opacity(0.88),
                controlFill: Color(red: 0.22, green: 0.17, blue: 0.13).opacity(0.84),
                selectionOpacity: 0.22,
                tabSelectionFill: Color(red: 1.00, green: 0.66, blue: 0.18).opacity(0.24),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 1.00, green: 0.66, blue: 0.18).opacity(0.12),
                hairline: Color(red: 0.96, green: 0.50, blue: 0.18).opacity(0.22),
                foregroundHex: 0xF4E9DD,
                backgroundHex: 0x211915,
                caretHex: 0xF57D24,
                ansi: [
                    0x2B211C, 0xE05A3A, 0xB8BB26, 0xF0A94A,
                    0x83A598, 0xE08BB0, 0x8EC07C, 0xE6D5C3,
                    0x5C4A3E, 0xF07050, 0xC8CC48, 0xF5C066,
                    0x9CBAB0, 0xF0A0C0, 0xA6D090, 0xF4E9DD
                ]
            )
        case .dusk:
            return TerminalSkinSpec(
                symbolName: "cloud.moon",
                isDark: true,
                accent: Color(red: 0.74, green: 0.58, blue: 0.98),
                secondaryAccent: Color(red: 1.00, green: 0.47, blue: 0.78),
                windowStops: [
                    Color(red: 0.16, green: 0.15, blue: 0.21),
                    Color(red: 0.19, green: 0.17, blue: 0.26),
                    Color(red: 0.13, green: 0.12, blue: 0.18)
                ],
                sidebarStops: [
                    Color(red: 0.15, green: 0.14, blue: 0.20).opacity(0.96),
                    Color(red: 0.19, green: 0.16, blue: 0.26).opacity(0.92)
                ],
                panelFill: Color(red: 0.16, green: 0.15, blue: 0.22).opacity(0.88),
                controlFill: Color(red: 0.20, green: 0.18, blue: 0.27).opacity(0.84),
                selectionOpacity: 0.24,
                tabSelectionFill: Color(red: 0.74, green: 0.58, blue: 0.98).opacity(0.28),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 1.00, green: 0.47, blue: 0.78).opacity(0.12),
                hairline: Color(red: 0.74, green: 0.58, blue: 0.98).opacity(0.24),
                foregroundHex: 0xF8F8F2,
                backgroundHex: 0x282A36,
                caretHex: 0xBD93F9,
                ansi: [
                    0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                    0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                    0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                    0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
                ]
            )
        case .polar:
            return TerminalSkinSpec(
                symbolName: "snowflake",
                isDark: true,
                accent: Color(red: 0.51, green: 0.63, blue: 0.76),
                secondaryAccent: Color(red: 0.53, green: 0.75, blue: 0.82),
                windowStops: [
                    Color(red: 0.16, green: 0.19, blue: 0.24),
                    Color(red: 0.20, green: 0.24, blue: 0.30),
                    Color(red: 0.14, green: 0.17, blue: 0.22)
                ],
                sidebarStops: [
                    Color(red: 0.15, green: 0.18, blue: 0.23).opacity(0.96),
                    Color(red: 0.19, green: 0.23, blue: 0.29).opacity(0.92)
                ],
                panelFill: Color(red: 0.17, green: 0.20, blue: 0.26).opacity(0.88),
                controlFill: Color(red: 0.22, green: 0.26, blue: 0.33).opacity(0.84),
                selectionOpacity: 0.22,
                tabSelectionFill: Color(red: 0.51, green: 0.63, blue: 0.76).opacity(0.26),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.53, green: 0.75, blue: 0.82).opacity(0.12),
                hairline: Color(red: 0.51, green: 0.63, blue: 0.76).opacity(0.24),
                foregroundHex: 0xD8DEE9,
                backgroundHex: 0x2E3440,
                caretHex: 0x88C0D0,
                ansi: [
                    0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                    0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                    0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                    0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4
                ]
            )
        case .carbon:
            return TerminalSkinSpec(
                symbolName: "cube",
                isDark: true,
                accent: Color(red: 0.38, green: 0.69, blue: 0.94),
                secondaryAccent: Color(red: 0.78, green: 0.47, blue: 0.87),
                windowStops: [
                    Color(red: 0.15, green: 0.17, blue: 0.20),
                    Color(red: 0.17, green: 0.19, blue: 0.23),
                    Color(red: 0.13, green: 0.15, blue: 0.18)
                ],
                sidebarStops: [
                    Color(red: 0.14, green: 0.16, blue: 0.19).opacity(0.96),
                    Color(red: 0.17, green: 0.19, blue: 0.23).opacity(0.92)
                ],
                panelFill: Color(red: 0.16, green: 0.17, blue: 0.21).opacity(0.88),
                controlFill: Color(red: 0.20, green: 0.22, blue: 0.26).opacity(0.84),
                selectionOpacity: 0.22,
                tabSelectionFill: Color(red: 0.38, green: 0.69, blue: 0.94).opacity(0.26),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.78, green: 0.47, blue: 0.87).opacity(0.12),
                hairline: Color(red: 0.38, green: 0.69, blue: 0.94).opacity(0.22),
                foregroundHex: 0xABB2BF,
                backgroundHex: 0x282C34,
                caretHex: 0x61AFEF,
                ansi: [
                    0x282C34, 0xE06C75, 0x98C379, 0xE5C07B,
                    0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
                    0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B,
                    0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF
                ]
            )
        case .abyss:
            return TerminalSkinSpec(
                symbolName: "drop.fill",
                isDark: true,
                accent: Color(red: 0.16, green: 0.72, blue: 0.74),
                secondaryAccent: Color(red: 0.30, green: 0.55, blue: 0.85),
                windowStops: [
                    Color(red: 0.04, green: 0.13, blue: 0.16),
                    Color(red: 0.06, green: 0.17, blue: 0.20),
                    Color(red: 0.03, green: 0.10, blue: 0.13)
                ],
                sidebarStops: [
                    Color(red: 0.04, green: 0.12, blue: 0.15).opacity(0.96),
                    Color(red: 0.05, green: 0.16, blue: 0.20).opacity(0.92)
                ],
                panelFill: Color(red: 0.05, green: 0.15, blue: 0.18).opacity(0.88),
                controlFill: Color(red: 0.07, green: 0.19, blue: 0.23).opacity(0.84),
                selectionOpacity: 0.22,
                tabSelectionFill: Color(red: 0.16, green: 0.72, blue: 0.74).opacity(0.26),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.30, green: 0.55, blue: 0.85).opacity(0.12),
                hairline: Color(red: 0.16, green: 0.72, blue: 0.74).opacity(0.24),
                foregroundHex: 0xCDE8EA,
                backgroundHex: 0x081E22,
                caretHex: 0x2AB7BE,
                ansi: [
                    0x0A2429, 0xE05561, 0x33C08D, 0xE0B15A,
                    0x3D8FD1, 0xB07BD6, 0x2CC0C8, 0xB8D4D6,
                    0x3A5B60, 0xF06E78, 0x4FD9A4, 0xF0C572,
                    0x59A6E0, 0xC694E8, 0x4FD8E0, 0xE6F4F5
                ]
            )
        case .garnet:
            return TerminalSkinSpec(
                symbolName: "diamond.fill",
                isDark: true,
                accent: Color(red: 0.86, green: 0.30, blue: 0.38),
                secondaryAccent: Color(red: 0.92, green: 0.58, blue: 0.30),
                windowStops: [
                    Color(red: 0.15, green: 0.09, blue: 0.10),
                    Color(red: 0.20, green: 0.11, blue: 0.12),
                    Color(red: 0.11, green: 0.07, blue: 0.08)
                ],
                sidebarStops: [
                    Color(red: 0.14, green: 0.08, blue: 0.09).opacity(0.96),
                    Color(red: 0.19, green: 0.10, blue: 0.11).opacity(0.92)
                ],
                panelFill: Color(red: 0.17, green: 0.10, blue: 0.11).opacity(0.88),
                controlFill: Color(red: 0.22, green: 0.13, blue: 0.14).opacity(0.84),
                selectionOpacity: 0.22,
                tabSelectionFill: Color(red: 0.92, green: 0.58, blue: 0.30).opacity(0.24),
                tabSelectionBorderOpacity: 0.36,
                hoverFill: Color(red: 0.92, green: 0.58, blue: 0.30).opacity(0.12),
                hairline: Color(red: 0.86, green: 0.30, blue: 0.38).opacity(0.22),
                foregroundHex: 0xF3DBDD,
                backgroundHex: 0x1E1113,
                caretHex: 0xE04756,
                ansi: [
                    0x2A1A1C, 0xE0555F, 0xA3B85C, 0xE0A84A,
                    0x9A7BD0, 0xE06B9E, 0x4FB8AE, 0xE8D5D6,
                    0x6A4A4E, 0xF06E78, 0xB8CC70, 0xF0C066,
                    0xB294E0, 0xF086B4, 0x66CEC4, 0xF3DBDD
                ]
            )
        }
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    func withOpacity(_ opacity: CGFloat) -> NSColor {
        withAlphaComponent(max(0, min(opacity, 1)))
    }
}
