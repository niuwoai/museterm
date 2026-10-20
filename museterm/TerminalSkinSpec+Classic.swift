import AppKit
import SwiftUI

extension TerminalSkinSpec {
    /// 终端保留上游原始色值，界面层次由同一组前背景色派生。
    static func classic(
        symbol: String,
        isDark: Bool,
        foreground: Int,
        background: Int,
        caret: Int,
        ansi: [Int]
    ) -> TerminalSkinSpec {
        let base = NSColor(hex: background)
        let text = NSColor(hex: foreground)
        let accent = Color(nsColor: NSColor(hex: ansi[4]))
        let secondaryAccent = Color(nsColor: NSColor(hex: ansi[5]))
        let surface = Color(nsColor: base.blended(withFraction: 0.045, of: text) ?? base)
        let raised = Color(nsColor: base.blended(withFraction: 0.08, of: text) ?? base)

        return TerminalSkinSpec(
            symbolName: symbol,
            isDark: isDark,
            accent: accent,
            secondaryAccent: secondaryAccent,
            windowStops: [Color(nsColor: base), surface, Color(nsColor: base)],
            sidebarStops: [surface.opacity(0.96), raised.opacity(0.92)],
            panelFill: surface,
            controlFill: raised,
            selectionOpacity: isDark ? 0.24 : 0.16,
            tabSelectionFill: accent.opacity(isDark ? 0.24 : 0.16),
            tabSelectionBorderOpacity: isDark ? 0.42 : 0.32,
            hoverFill: secondaryAccent.opacity(0.10),
            hairline: Color(nsColor: text).opacity(0.18),
            foregroundHex: foreground,
            backgroundHex: background,
            caretHex: caret,
            ansi: ansi
        )
    }
}
