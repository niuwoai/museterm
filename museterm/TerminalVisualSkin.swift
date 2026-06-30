import AppKit
import SwiftUI

enum TerminalVisualSkin: String, CaseIterable, Identifiable {
    case seaSalt
    case mist
    case ink
    case midnight
    case aurora
    case ember

    var id: String { rawValue }

    var name: String {
        L10n.string("skin.\(rawValue).name")
    }

    var summary: String {
        L10n.string("skin.\(rawValue).summary")
    }

    var symbolName: String {
        switch self {
        case .seaSalt: return "water.waves"
        case .mist: return "leaf"
        case .ink: return "paintbrush.pointed"
        case .midnight: return "moon.stars"
        case .aurora: return "waveform.path.ecg"
        case .ember: return "flame"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .seaSalt, .mist, .ink: return .light
        case .midnight, .aurora, .ember: return .dark
        }
    }

    var accent: Color {
        switch self {
        case .seaSalt: return Color(red: 0.17, green: 0.52, blue: 0.64)
        case .mist: return Color(red: 0.23, green: 0.48, blue: 0.42)
        case .ink: return Color(red: 0.18, green: 0.25, blue: 0.31)
        case .midnight: return Color(red: 0.42, green: 0.52, blue: 0.96)
        case .aurora: return Color(red: 0.20, green: 0.78, blue: 0.54)
        case .ember: return Color(red: 0.96, green: 0.49, blue: 0.14)
        }
    }

    var secondaryAccent: Color {
        switch self {
        case .seaSalt: return Color(red: 0.86, green: 0.57, blue: 0.36)
        case .mist: return Color(red: 0.77, green: 0.46, blue: 0.35)
        case .ink: return Color(red: 0.58, green: 0.43, blue: 0.23)
        case .midnight: return Color(red: 0.50, green: 0.68, blue: 1.00)
        case .aurora: return Color(red: 0.22, green: 0.63, blue: 0.88)
        case .ember: return Color(red: 1.00, green: 0.66, blue: 0.18)
        }
    }

    var windowBackground: LinearGradient {
        switch self {
        case .seaSalt:
            return LinearGradient(colors: [
                Color(red: 0.91, green: 0.97, blue: 0.98),
                Color(red: 0.95, green: 0.96, blue: 0.90),
                Color(red: 0.86, green: 0.94, blue: 0.95)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mist:
            return LinearGradient(colors: [
                Color(red: 0.94, green: 0.98, blue: 0.95),
                Color(red: 0.98, green: 0.95, blue: 0.91),
                Color(red: 0.90, green: 0.96, blue: 0.98)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ink:
            return LinearGradient(colors: [
                Color(red: 0.93, green: 0.92, blue: 0.88),
                Color(red: 0.83, green: 0.86, blue: 0.84),
                Color(red: 0.96, green: 0.94, blue: 0.89)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .midnight:
            return LinearGradient(colors: [
                Color(red: 0.08, green: 0.10, blue: 0.17),
                Color(red: 0.11, green: 0.13, blue: 0.23),
                Color(red: 0.17, green: 0.18, blue: 0.29)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            return LinearGradient(colors: [
                Color(red: 0.04, green: 0.16, blue: 0.13),
                Color(red: 0.08, green: 0.27, blue: 0.20),
                Color(red: 0.04, green: 0.11, blue: 0.17)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ember:
            return LinearGradient(colors: [
                Color(red: 0.15, green: 0.12, blue: 0.10),
                Color(red: 0.22, green: 0.17, blue: 0.13),
                Color(red: 0.10, green: 0.09, blue: 0.08)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var sidebarBackground: LinearGradient {
        switch self {
        case .seaSalt:
            return LinearGradient(colors: [
                Color(red: 0.86, green: 0.95, blue: 0.97).opacity(0.94),
                Color(red: 0.98, green: 0.94, blue: 0.86).opacity(0.78)
            ], startPoint: .top, endPoint: .bottom)
        case .mist:
            return LinearGradient(colors: [
                Color(red: 0.90, green: 0.97, blue: 0.92).opacity(0.92),
                Color(red: 0.98, green: 0.93, blue: 0.88).opacity(0.82)
            ], startPoint: .top, endPoint: .bottom)
        case .ink:
            return LinearGradient(colors: [
                Color(red: 0.88, green: 0.88, blue: 0.84).opacity(0.95),
                Color(red: 0.76, green: 0.80, blue: 0.78).opacity(0.85)
            ], startPoint: .top, endPoint: .bottom)
        case .midnight:
            return LinearGradient(colors: [
                Color(red: 0.07, green: 0.09, blue: 0.16).opacity(0.96),
                Color(red: 0.14, green: 0.15, blue: 0.24).opacity(0.92)
            ], startPoint: .top, endPoint: .bottom)
        case .aurora:
            return LinearGradient(colors: [
                Color(red: 0.03, green: 0.15, blue: 0.12).opacity(0.96),
                Color(red: 0.05, green: 0.19, blue: 0.24).opacity(0.92)
            ], startPoint: .top, endPoint: .bottom)
        case .ember:
            return LinearGradient(colors: [
                Color(red: 0.18, green: 0.14, blue: 0.11).opacity(0.96),
                Color(red: 0.10, green: 0.08, blue: 0.07).opacity(0.92)
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    var panelFill: Color {
        switch self {
        case .seaSalt: return Color.white.opacity(0.58)
        case .mist: return Color.white.opacity(0.54)
        case .ink: return Color(red: 0.98, green: 0.96, blue: 0.90).opacity(0.48)
        case .midnight: return Color(red: 0.10, green: 0.12, blue: 0.21).opacity(0.88)
        case .aurora: return Color(red: 0.05, green: 0.18, blue: 0.16).opacity(0.86)
        case .ember: return Color(red: 0.18, green: 0.14, blue: 0.11).opacity(0.88)
        }
    }

    var controlFill: Color {
        switch self {
        case .seaSalt: return Color(red: 0.98, green: 0.99, blue: 0.96).opacity(0.76)
        case .mist: return Color.white.opacity(0.72)
        case .ink: return Color(red: 0.97, green: 0.95, blue: 0.88).opacity(0.74)
        case .midnight: return Color(red: 0.14, green: 0.16, blue: 0.27).opacity(0.84)
        case .aurora: return Color(red: 0.08, green: 0.23, blue: 0.20).opacity(0.84)
        case .ember: return Color(red: 0.22, green: 0.17, blue: 0.13).opacity(0.84)
        }
    }

    var selectionFill: Color {
        switch self {
        case .seaSalt: return accent.opacity(0.16)
        case .mist: return accent.opacity(0.17)
        case .ink: return accent.opacity(0.15)
        case .midnight: return accent.opacity(0.24)
        case .aurora: return accent.opacity(0.20)
        case .ember: return accent.opacity(0.22)
        }
    }

    var hoverFill: Color {
        switch self {
        case .seaSalt: return secondaryAccent.opacity(0.10)
        case .mist: return secondaryAccent.opacity(0.10)
        case .ink: return Color.black.opacity(0.07)
        case .midnight: return secondaryAccent.opacity(0.13)
        case .aurora: return accent.opacity(0.12)
        case .ember: return secondaryAccent.opacity(0.12)
        }
    }

    var hairline: Color {
        switch self {
        case .seaSalt: return Color(red: 0.22, green: 0.46, blue: 0.52).opacity(0.17)
        case .mist: return Color(red: 0.28, green: 0.43, blue: 0.36).opacity(0.18)
        case .ink: return Color(red: 0.22, green: 0.25, blue: 0.24).opacity(0.20)
        case .midnight: return Color(red: 0.45, green: 0.55, blue: 0.96).opacity(0.24)
        case .aurora: return Color(red: 0.25, green: 0.86, blue: 0.62).opacity(0.24)
        case .ember: return Color(red: 0.96, green: 0.50, blue: 0.18).opacity(0.22)
        }
    }

    var terminalForeground: NSColor {
        switch self {
        case .seaSalt: return NSColor(hex: 0x183640)
        case .mist: return NSColor(hex: 0x17382F)
        case .ink: return NSColor(hex: 0x243238)
        case .midnight: return NSColor(hex: 0xD9E6FF)
        case .aurora: return NSColor(hex: 0xD8F7EA)
        case .ember: return NSColor(hex: 0xF4E9DD)
        }
    }

    var terminalBackground: NSColor {
        switch self {
        case .seaSalt: return NSColor(hex: 0xE8F4F3)
        case .mist: return NSColor(hex: 0xEAF5EC)
        case .ink: return NSColor(hex: 0xE7E3D7)
        case .midnight: return NSColor(hex: 0x121725)
        case .aurora: return NSColor(hex: 0x081F1A)
        case .ember: return NSColor(hex: 0x211915)
        }
    }

    var caret: NSColor {
        switch self {
        case .seaSalt: return NSColor(hex: 0x2B85A3)
        case .mist: return NSColor(hex: 0x3B7A6B)
        case .ink: return NSColor(hex: 0x2E404F)
        case .midnight: return NSColor(hex: 0x7FAAFF)
        case .aurora: return NSColor(hex: 0x33C789)
        case .ember: return NSColor(hex: 0xF57D24)
        }
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    func withOpacity(_ opacity: CGFloat) -> NSColor {
        withAlphaComponent(max(0, min(opacity, 1)))
    }
}
