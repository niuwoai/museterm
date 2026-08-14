import SwiftTerm

extension TerminalVisualSkin {
    /// 皮肤内置的 ANSI 16 色（用于终端渲染）。
    var ansiSwiftTermColors: [SwiftTerm.Color] {
        ansiHexColors.map(Self.swiftTermColor)
    }

    nonisolated private static func swiftTermColor(hex: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
