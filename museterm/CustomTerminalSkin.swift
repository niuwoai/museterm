import AppKit
import SwiftUI

/// 用户从内置皮肤复制出的可编辑终端配色。窗口外观沿用来源皮肤，
/// 以免仅调整 ANSI 色时意外破坏整套界面的层级与对比度。
struct CustomTerminalSkin: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceSkinID: String
    var name: String
    var foregroundHex: Int
    var backgroundHex: Int
    var caretHex: Int
    var ansi: [Int]

    init(source: TerminalVisualSkin, name: String) {
        id = UUID()
        sourceSkinID = source.rawValue
        self.name = name
        foregroundHex = source.spec.foregroundHex
        backgroundHex = source.spec.backgroundHex
        caretHex = source.spec.caretHex
        ansi = source.ansiHexColors
    }

    var sourceSkin: TerminalVisualSkin {
        TerminalVisualSkin(rawValue: sourceSkinID) ?? .midnight
    }

    var spec: TerminalSkinSpec {
        let base = sourceSkin.spec
        return TerminalSkinSpec(
            symbolName: "paintpalette",
            isDark: isDark,
            accent: Color(nsColor: caret),
            secondaryAccent: base.secondaryAccent,
            windowStops: base.windowStops,
            sidebarStops: base.sidebarStops,
            panelFill: base.panelFill,
            controlFill: base.controlFill,
            selectionOpacity: base.selectionOpacity,
            tabSelectionFill: base.tabSelectionFill,
            tabSelectionBorderOpacity: base.tabSelectionBorderOpacity,
            hoverFill: base.hoverFill,
            hairline: base.hairline,
            foregroundHex: foregroundHex,
            backgroundHex: backgroundHex,
            caretHex: caretHex,
            ansi: normalizedANSI
        )
    }

    var normalizedANSI: [Int] {
        let fallback = sourceSkin.ansiHexColors
        return (0..<fallback.count).map { ansi.indices.contains($0) ? ansi[$0] : fallback[$0] }
    }

    var isDark: Bool {
        let red = Double((backgroundHex >> 16) & 0xFF)
        let green = Double((backgroundHex >> 8) & 0xFF)
        let blue = Double(backgroundHex & 0xFF)
        return (red * 0.2126 + green * 0.7152 + blue * 0.0722) < 150
    }

    var foreground: NSColor { NSColor(hex: foregroundHex) }
    var background: NSColor { NSColor(hex: backgroundHex) }
    var caret: NSColor { NSColor(hex: caretHex) }
}

enum CustomTerminalSkinStore {
    private static var active: CustomTerminalSkin?

    static func activate(_ skin: CustomTerminalSkin?) {
        active = skin
    }

    static var activeSkin: CustomTerminalSkin? { active }
}
