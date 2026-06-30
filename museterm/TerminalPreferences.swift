import AppKit
import Combine
import Foundation

enum GlassMaterial: String, CaseIterable, Identifiable {
    case underWindow
    case hudWindow
    case sidebar
    case fullScreen
    case menu

    var id: String { rawValue }

    var name: String {
        L10n.string("glass.material.\(rawValue)")
    }

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .underWindow: return .underWindowBackground
        case .hudWindow: return .hudWindow
        case .sidebar: return .sidebar
        case .fullScreen: return .fullScreenUI
        case .menu: return .menu
        }
    }
}

final class TerminalPreferences: ObservableObject {
    private enum Keys {
        static let skin = "terminal.skin"
        static let colorPalette = "terminal.colorPalette"
        static let fontFamily = "terminal.fontFamily"
        static let fallbackFontFamily = "terminal.fallbackFontFamily"
        static let fontSize = "terminal.fontSize"
        static let lineHeight = "terminal.lineHeight"
        static let glassEnabled = "terminal.glassEnabled"
        static let glassMaterial = "terminal.glassMaterial"
        static let glassOpacity = "terminal.glassOpacity"
        static let terminalOpacity = "terminal.terminalOpacity"
        static let tintOpacity = "terminal.tintOpacity"
        static let glow = "terminal.glow"
        static let optionAsMeta = "terminal.optionAsMeta"
        static let mouseReporting = "terminal.mouseReporting"
        static let showsTabList = "terminal.showsTabList"
        static let appIcon = "app.icon"
    }

    private let defaults: UserDefaults

    @Published var skin: TerminalVisualSkin { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
    @Published var colorPalette: TerminalColorPalette { didSet { defaults.set(colorPalette.rawValue, forKey: Keys.colorPalette) } }
    @Published var fontFamily: String { didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) } }
    @Published var fallbackFontFamily: String { didSet { defaults.set(fallbackFontFamily, forKey: Keys.fallbackFontFamily) } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    @Published var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: Keys.lineHeight) } }
    @Published var glassEnabled: Bool { didSet { defaults.set(glassEnabled, forKey: Keys.glassEnabled) } }
    @Published var glassMaterial: GlassMaterial { didSet { defaults.set(glassMaterial.rawValue, forKey: Keys.glassMaterial) } }
    @Published var glassOpacity: Double { didSet { defaults.set(glassOpacity, forKey: Keys.glassOpacity) } }
    @Published var terminalOpacity: Double { didSet { defaults.set(terminalOpacity, forKey: Keys.terminalOpacity) } }
    @Published var tintOpacity: Double { didSet { defaults.set(tintOpacity, forKey: Keys.tintOpacity) } }
    @Published var glow: Double { didSet { defaults.set(glow, forKey: Keys.glow) } }
    @Published var optionAsMeta: Bool { didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) } }
    @Published var mouseReporting: Bool { didSet { defaults.set(mouseReporting, forKey: Keys.mouseReporting) } }
    @Published var showsTabList: Bool { didSet { defaults.set(showsTabList, forKey: Keys.showsTabList) } }
    @Published var appIcon: AppIconChoice {
        didSet {
            defaults.set(appIcon.rawValue, forKey: Keys.appIcon)
            AppIconManager.apply(appIcon)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skin = TerminalVisualSkin(rawValue: defaults.string(forKey: Keys.skin) ?? "") ?? .seaSalt
        colorPalette = TerminalColorPalette(rawValue: defaults.string(forKey: Keys.colorPalette) ?? "") ?? .apple
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "SF Mono"
        fallbackFontFamily = defaults.string(forKey: Keys.fallbackFontFamily) ?? "PingFang SC"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 14
        lineHeight = defaults.object(forKey: Keys.lineHeight) as? Double ?? 1.08
        glassEnabled = defaults.object(forKey: Keys.glassEnabled) as? Bool ?? true
        glassMaterial = GlassMaterial(rawValue: defaults.string(forKey: Keys.glassMaterial) ?? "") ?? .underWindow
        glassOpacity = defaults.object(forKey: Keys.glassOpacity) as? Double ?? 0.72
        terminalOpacity = defaults.object(forKey: Keys.terminalOpacity) as? Double ?? 0.86
        tintOpacity = defaults.object(forKey: Keys.tintOpacity) as? Double ?? 0.20
        glow = defaults.object(forKey: Keys.glow) as? Double ?? 0.24
        optionAsMeta = defaults.object(forKey: Keys.optionAsMeta) as? Bool ?? true
        mouseReporting = defaults.object(forKey: Keys.mouseReporting) as? Bool ?? true
        showsTabList = defaults.object(forKey: Keys.showsTabList) as? Bool ?? true
        appIcon = AppIconChoice(rawValue: defaults.string(forKey: Keys.appIcon) ?? "") ?? .defaultTerminal
        AppIconManager.apply(appIcon)
    }

    var terminalFont: NSFont {
        TerminalFontResolver.font(
            primaryFamily: fontFamily,
            fallbackFamily: fallbackFontFamily,
            size: CGFloat(fontSize)
        )
    }
}

enum TerminalFontResolver {
    static var installedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func font(primaryFamily: String, fallbackFamily: String, size: CGFloat) -> NSFont {
        let base = font(named: primaryFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        guard let fallback = font(named: fallbackFamily, size: size) else {
            return base
        }

        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [fallback.fontDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func font(named family: String, size: CGFloat) -> NSFont? {
        NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }
}
