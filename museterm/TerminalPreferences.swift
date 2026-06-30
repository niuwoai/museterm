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

enum TerminalCursorShape: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var name: String {
        L10n.string("cursor.shape.\(rawValue)")
    }
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case google
    case azureOpenAI
    case openRouter
    case ollama
    case custom

    var id: String { rawValue }

    var name: String {
        L10n.string("ai.provider.\(rawValue).name")
    }

    var summary: String {
        L10n.string("ai.provider.\(rawValue).summary")
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4.1"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .google: return "gemini-2.5-pro"
        case .azureOpenAI: return ""
        case .openRouter: return "openai/gpt-4.1"
        case .ollama: return "llama3.1"
        case .custom: return ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .azureOpenAI: return ""
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .custom: return ""
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
        static let cursorShape = "terminal.cursorShape"
        static let cursorBlink = "terminal.cursorBlink"
        static let confirmMultilinePaste = "terminal.confirmMultilinePaste"
        static let confirmDangerousCommands = "terminal.confirmDangerousCommands"
        static let customDangerousCommandRules = "terminal.customDangerousCommandRules"
        static let appIcon = "app.icon"
        static let aiProvider = "ai.provider"
        static let aiModel = "ai.model"
        static let aiBaseURL = "ai.baseURL"
        static let aiCustomProviderName = "ai.customProviderName"
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
    @Published var cursorShape: TerminalCursorShape { didSet { defaults.set(cursorShape.rawValue, forKey: Keys.cursorShape) } }
    @Published var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: Keys.cursorBlink) } }
    @Published var confirmMultilinePaste: Bool { didSet { defaults.set(confirmMultilinePaste, forKey: Keys.confirmMultilinePaste) } }
    @Published var confirmDangerousCommands: Bool { didSet { defaults.set(confirmDangerousCommands, forKey: Keys.confirmDangerousCommands) } }
    @Published var customDangerousCommandRules: String { didSet { defaults.set(customDangerousCommandRules, forKey: Keys.customDangerousCommandRules) } }
    @Published var aiProvider: AIProviderKind {
        didSet {
            defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider)
            if aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiModel = aiProvider.defaultModel
            }
            if aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiBaseURL = aiProvider.defaultBaseURL
            }
        }
    }
    @Published var aiModel: String { didSet { defaults.set(aiModel, forKey: Keys.aiModel) } }
    @Published var aiBaseURL: String { didSet { defaults.set(aiBaseURL, forKey: Keys.aiBaseURL) } }
    @Published var aiCustomProviderName: String { didSet { defaults.set(aiCustomProviderName, forKey: Keys.aiCustomProviderName) } }
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
        cursorShape = TerminalCursorShape(rawValue: defaults.string(forKey: Keys.cursorShape) ?? "") ?? .block
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        confirmMultilinePaste = defaults.object(forKey: Keys.confirmMultilinePaste) as? Bool ?? true
        confirmDangerousCommands = defaults.object(forKey: Keys.confirmDangerousCommands) as? Bool ?? true
        customDangerousCommandRules = defaults.string(forKey: Keys.customDangerousCommandRules) ?? ""
        let storedAIProvider = AIProviderKind(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .openAI
        aiProvider = storedAIProvider
        aiModel = defaults.string(forKey: Keys.aiModel) ?? storedAIProvider.defaultModel
        aiBaseURL = defaults.string(forKey: Keys.aiBaseURL) ?? storedAIProvider.defaultBaseURL
        aiCustomProviderName = defaults.string(forKey: Keys.aiCustomProviderName) ?? ""
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

    var aiDisplayProviderName: String {
        let customName = aiCustomProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiProvider == .custom, !customName.isEmpty {
            return customName
        }
        return aiProvider.name
    }

    var hasAIAPIKey: Bool {
        !MuseTermKeychain.load(account: aiAPIKeyAccount).isEmpty
    }

    func loadAIAPIKey() -> String {
        MuseTermKeychain.load(account: aiAPIKeyAccount)
    }

    func saveAIAPIKey(_ apiKey: String) {
        MuseTermKeychain.save(apiKey, account: aiAPIKeyAccount)
        objectWillChange.send()
    }

    func clearAIAPIKey() {
        MuseTermKeychain.delete(account: aiAPIKeyAccount)
        objectWillChange.send()
    }

    private var aiAPIKeyAccount: String {
        "ai-provider/\(aiProvider.rawValue)/api-key"
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
