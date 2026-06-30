import AppKit
import SwiftTerm

enum TerminalColorPalette: String, CaseIterable, Identifiable {
    case apple
    case tango
    case solarizedLight
    case solarizedDark
    case dracula
    case oneDark
    case nord

    var id: String { rawValue }

    var name: String {
        L10n.string("palette.\(rawValue).name")
    }

    var summary: String {
        L10n.string("palette.\(rawValue).summary")
    }

    var nsColors: [NSColor] {
        hexColors.map { NSColor(hex: $0) }
    }

    var swiftTermColors: [SwiftTerm.Color] {
        hexColors.map(Self.swiftTermColor)
    }

    private var hexColors: [Int] {
        switch self {
        case .apple:
            return [
                0x000000, 0xC23621, 0x25BC24, 0xADAD27,
                0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
                0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB
            ]
        case .tango:
            return [
                0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000,
                0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
                0x555753, 0xEF2929, 0x8AE234, 0xFCE94F,
                0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC
            ]
        case .solarizedLight, .solarizedDark:
            return [
                0x073642, 0xDC322F, 0x859900, 0xB58900,
                0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
            ]
        case .dracula:
            return [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
            ]
        case .oneDark:
            return [
                0x282C34, 0xE06C75, 0x98C379, 0xE5C07B,
                0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
                0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B,
                0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF
            ]
        case .nord:
            return [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4
            ]
        }
    }

    nonisolated private static func swiftTermColor(hex: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
