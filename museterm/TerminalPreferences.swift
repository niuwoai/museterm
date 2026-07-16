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

struct AIProviderBaseURLPreset: Identifiable, Hashable {
    let id: String
    let titleKey: String
    let url: String

    var title: String {
        L10n.string(titleKey)
    }
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case google
    case azureOpenAI
    case openRouter
    case someIM
    case ollama
    case llamaServer
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
        case .someIM: return "someim-auto-flash"
        case .ollama: return "llama3.1"
        case .llamaServer: return ""
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
        case .someIM: return "https://api.niuwoai.com/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .llamaServer: return "http://127.0.0.1:8080/v1"
        case .custom: return ""
        }
    }

    var baseURLPresets: [AIProviderBaseURLPreset] {
        switch self {
        case .someIM:
            return [
                AIProviderBaseURLPreset(
                    id: "china",
                    titleKey: "ai.provider.someIM.base_url.china",
                    url: "https://api.niuwoai.com/v1"
                ),
                AIProviderBaseURLPreset(
                    id: "global",
                    titleKey: "ai.provider.someIM.base_url.global",
                    url: "https://some.im/v1"
                )
            ]
        default:
            return []
        }
    }

    var isLocalProvider: Bool {
        switch self {
        case .ollama, .llamaServer: return true
        default: return false
        }
    }

    func isBuiltInBaseURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return defaultBaseURL == trimmed || baseURLPresets.contains { $0.url == trimmed }
    }

    static var builtInDefaultBaseURLs: Set<String> {
        Set(allCases.flatMap { provider in
            [provider.defaultBaseURL] + provider.baseURLPresets.map(\.url)
        }.filter { !$0.isEmpty })
    }

    static var builtInDefaultModels: Set<String> {
        Set(allCases.map(\.defaultModel).filter { !$0.isEmpty })
    }
}

final class TerminalPreferences: ObservableObject {
    private static let aiKeychainServiceName = "im.some.museterm.ai-credentials"

    private enum Keys {
        static let skin = "terminal.skin"
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
        static let scrollbackLines = "terminal.scrollbackLines"
        static let showsTabList = "terminal.showsTabList"
        static let cursorShape = "terminal.cursorShape"
        static let cursorBlink = "terminal.cursorBlink"
        static let appShortcuts = "terminal.shortcuts.app"
        static let lineStartShortcut = "terminal.shortcut.lineStart"
        static let lineEndShortcut = "terminal.shortcut.lineEnd"
        static let aiCommandActivation = "terminal.aiCommandActivation"
        static let confirmMultilinePaste = "terminal.confirmMultilinePaste"
        static let confirmDangerousCommands = "terminal.confirmDangerousCommands"
        static let customDangerousCommandRules = "terminal.customDangerousCommandRules"
        static let notificationsEnabled = "notifications.enabled"
        static let showInactiveTabNotificationBadges = "notifications.showInactiveTabBadges"
        static let notifyTerminalBell = "notifications.terminalBell"
        static let notifyCommandFailures = "notifications.commandFailures"
        static let notifyLongCommandCompletion = "notifications.longCommandCompletion"
        static let notifyProcessExits = "notifications.processExits"
        static let longCommandNotificationThresholdSeconds = "notifications.longCommandThresholdSeconds"
        static let failureNotificationMinimumDurationSeconds = "notifications.failureMinimumDurationSeconds"
        static let notificationCooldownSeconds = "notifications.cooldownSeconds"
        static let includeCommandInNotifications = "notifications.includeCommand"
        static let appleScriptInputEnabled = "applescript.inputEnabled"
        static let detachedPanelOpacity = "detachedPanel.opacity"
        static let appIcon = "app.icon"
        static let aiProvider = "ai.provider"
        static let aiModel = "ai.model"
        static let aiBaseURL = "ai.baseURL"
        static let aiCustomProviderName = "ai.customProviderName"
    }

    private let defaults: UserDefaults
    static let minimumScrollbackLines = 500
    static let defaultScrollbackLines = 3_000
    static let maximumScrollbackLines = 20_000

    @Published var skin: TerminalVisualSkin { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
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
    @Published var scrollbackLines: Int {
        didSet {
            let normalized = Self.clampedScrollbackLines(scrollbackLines)
            guard scrollbackLines == normalized else {
                scrollbackLines = normalized
                return
            }
            defaults.set(scrollbackLines, forKey: Keys.scrollbackLines)
        }
    }
    @Published var showsTabList: Bool { didSet { defaults.set(showsTabList, forKey: Keys.showsTabList) } }
    @Published var cursorShape: TerminalCursorShape { didSet { defaults.set(cursorShape.rawValue, forKey: Keys.cursorShape) } }
    @Published var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: Keys.cursorBlink) } }
    @Published private(set) var appShortcutOverrides: [String: String] {
        didSet { defaults.set(appShortcutOverrides, forKey: Keys.appShortcuts) }
    }
    @Published var lineStartShortcut: String { didSet { defaults.set(lineStartShortcut, forKey: Keys.lineStartShortcut) } }
    @Published var lineEndShortcut: String { didSet { defaults.set(lineEndShortcut, forKey: Keys.lineEndShortcut) } }
    @Published var aiCommandActivation: AICommandActivation {
        didSet { defaults.set(aiCommandActivation.rawValue, forKey: Keys.aiCommandActivation) }
    }
    @Published var confirmMultilinePaste: Bool { didSet { defaults.set(confirmMultilinePaste, forKey: Keys.confirmMultilinePaste) } }
    @Published var confirmDangerousCommands: Bool { didSet { defaults.set(confirmDangerousCommands, forKey: Keys.confirmDangerousCommands) } }
    @Published var customDangerousCommandRules: String { didSet { defaults.set(customDangerousCommandRules, forKey: Keys.customDangerousCommandRules) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) } }
    @Published var showInactiveTabNotificationBadges: Bool { didSet { defaults.set(showInactiveTabNotificationBadges, forKey: Keys.showInactiveTabNotificationBadges) } }
    @Published var notifyTerminalBell: Bool { didSet { defaults.set(notifyTerminalBell, forKey: Keys.notifyTerminalBell) } }
    @Published var notifyCommandFailures: Bool { didSet { defaults.set(notifyCommandFailures, forKey: Keys.notifyCommandFailures) } }
    @Published var notifyLongCommandCompletion: Bool { didSet { defaults.set(notifyLongCommandCompletion, forKey: Keys.notifyLongCommandCompletion) } }
    @Published var notifyProcessExits: Bool { didSet { defaults.set(notifyProcessExits, forKey: Keys.notifyProcessExits) } }
    @Published var longCommandNotificationThresholdSeconds: Double { didSet { defaults.set(longCommandNotificationThresholdSeconds, forKey: Keys.longCommandNotificationThresholdSeconds) } }
    @Published var failureNotificationMinimumDurationSeconds: Double { didSet { defaults.set(failureNotificationMinimumDurationSeconds, forKey: Keys.failureNotificationMinimumDurationSeconds) } }
    @Published var notificationCooldownSeconds: Double { didSet { defaults.set(notificationCooldownSeconds, forKey: Keys.notificationCooldownSeconds) } }
    @Published var includeCommandInNotifications: Bool { didSet { defaults.set(includeCommandInNotifications, forKey: Keys.includeCommandInNotifications) } }
    @Published var appleScriptInputEnabled: Bool { didSet { defaults.set(appleScriptInputEnabled, forKey: Keys.appleScriptInputEnabled) } }
    // 分离悬浮面板的整体不透明度（含文字），默认 0.5，让面板半透融入桌面；与终端 glassOpacity 独立。
    @Published var detachedPanelOpacity: Double { didSet { defaults.set(detachedPanelOpacity, forKey: Keys.detachedPanelOpacity) } }
    @Published var aiProvider: AIProviderKind {
        didSet {
            let previousProvider = oldValue
            let previousBaseURL = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider)
            if previousModel.isEmpty || previousModel == previousProvider.defaultModel || AIProviderKind.builtInDefaultModels.contains(previousModel) {
                aiModel = aiProvider.defaultModel
            }
            if previousBaseURL.isEmpty || previousProvider.isBuiltInBaseURL(previousBaseURL) || AIProviderKind.builtInDefaultBaseURLs.contains(previousBaseURL) {
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
        scrollbackLines = Self.clampedScrollbackLines(
            defaults.object(forKey: Keys.scrollbackLines) as? Int ?? Self.defaultScrollbackLines
        )
        showsTabList = defaults.object(forKey: Keys.showsTabList) as? Bool ?? true
        cursorShape = TerminalCursorShape(rawValue: defaults.string(forKey: Keys.cursorShape) ?? "") ?? .block
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        appShortcutOverrides = (defaults.dictionary(forKey: Keys.appShortcuts) ?? [:])
            .compactMapValues { $0 as? String }
        lineStartShortcut = defaults.string(forKey: Keys.lineStartShortcut)
            ?? TerminalKeyBinding.defaultLineStart.storageValue
        lineEndShortcut = defaults.string(forKey: Keys.lineEndShortcut)
            ?? TerminalKeyBinding.defaultLineEnd.storageValue
        aiCommandActivation = AICommandActivation(
            rawValue: defaults.string(forKey: Keys.aiCommandActivation) ?? ""
        ) ?? .doubleControl
        confirmMultilinePaste = defaults.object(forKey: Keys.confirmMultilinePaste) as? Bool ?? true
        confirmDangerousCommands = defaults.object(forKey: Keys.confirmDangerousCommands) as? Bool ?? true
        customDangerousCommandRules = defaults.string(forKey: Keys.customDangerousCommandRules) ?? ""
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        showInactiveTabNotificationBadges = defaults.object(forKey: Keys.showInactiveTabNotificationBadges) as? Bool ?? true
        notifyTerminalBell = defaults.object(forKey: Keys.notifyTerminalBell) as? Bool ?? true
        notifyCommandFailures = defaults.object(forKey: Keys.notifyCommandFailures) as? Bool ?? true
        notifyLongCommandCompletion = defaults.object(forKey: Keys.notifyLongCommandCompletion) as? Bool ?? true
        notifyProcessExits = defaults.object(forKey: Keys.notifyProcessExits) as? Bool ?? false
        longCommandNotificationThresholdSeconds = defaults.object(forKey: Keys.longCommandNotificationThresholdSeconds) as? Double ?? 30
        failureNotificationMinimumDurationSeconds = defaults.object(forKey: Keys.failureNotificationMinimumDurationSeconds) as? Double ?? 5
        notificationCooldownSeconds = defaults.object(forKey: Keys.notificationCooldownSeconds) as? Double ?? 10
        includeCommandInNotifications = defaults.object(forKey: Keys.includeCommandInNotifications) as? Bool ?? false
        appleScriptInputEnabled = defaults.object(forKey: Keys.appleScriptInputEnabled) as? Bool ?? true
        detachedPanelOpacity = defaults.object(forKey: Keys.detachedPanelOpacity) as? Double ?? 0.5
        let storedAIProvider = AIProviderKind(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .someIM
        aiProvider = storedAIProvider
        aiModel = defaults.string(forKey: Keys.aiModel) ?? storedAIProvider.defaultModel
        aiBaseURL = defaults.string(forKey: Keys.aiBaseURL) ?? storedAIProvider.defaultBaseURL
        aiCustomProviderName = defaults.string(forKey: Keys.aiCustomProviderName) ?? ""
        appIcon = AppIconChoice(rawValue: defaults.string(forKey: Keys.appIcon) ?? "") ?? .defaultTerminal
        normalizeBuiltInAIProviderDefaults()
        AppIconManager.apply(appIcon)
    }

    static func clampedScrollbackLines(_ value: Int) -> Int {
        min(max(value, minimumScrollbackLines), maximumScrollbackLines)
    }

    func appShortcut(for action: TerminalAppShortcutAction) -> String {
        appShortcutOverrides[action.rawValue] ?? action.defaultStorageValue
    }

    func setAppShortcut(_ storageValue: String, for action: TerminalAppShortcutAction) {
        var nextOverrides = appShortcutOverrides
        if !storageValue.isEmpty {
            for otherAction in TerminalAppShortcutAction.allCases where otherAction != action {
                if appShortcut(for: otherAction) == storageValue {
                    nextOverrides[otherAction.rawValue] = ""
                }
            }
            if lineStartShortcut == storageValue { lineStartShortcut = "" }
            if lineEndShortcut == storageValue { lineEndShortcut = "" }
        }
        nextOverrides[action.rawValue] = storageValue
        appShortcutOverrides = nextOverrides
    }

    func restoreDefaultAppShortcuts() {
        let defaultValues = Set(TerminalAppShortcutAction.allCases.map(\.defaultStorageValue))
        if defaultValues.contains(lineStartShortcut) { lineStartShortcut = "" }
        if defaultValues.contains(lineEndShortcut) { lineEndShortcut = "" }
        appShortcutOverrides = [:]
        aiCommandActivation = .doubleControl
    }

    func setLineNavigationShortcut(_ storageValue: String, for action: TerminalLineNavigationAction) {
        var nextOverrides = appShortcutOverrides
        if !storageValue.isEmpty {
            for appAction in TerminalAppShortcutAction.allCases where appShortcut(for: appAction) == storageValue {
                nextOverrides[appAction.rawValue] = ""
            }
        }

        switch action {
        case .lineStart:
            lineStartShortcut = storageValue
            if !storageValue.isEmpty, lineEndShortcut == storageValue { lineEndShortcut = "" }
        case .lineEnd:
            lineEndShortcut = storageValue
            if !storageValue.isEmpty, lineStartShortcut == storageValue { lineStartShortcut = "" }
        }
        if nextOverrides != appShortcutOverrides {
            appShortcutOverrides = nextOverrides
        }
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
        !loadAIAPIKey().isEmpty
    }

    func loadAIAPIKey() -> String {
        let current = MuseTermKeychain.load(
            account: aiAPIKeyAccount,
            serviceName: Self.aiKeychainServiceName
        )
        guard current.isEmpty else { return current }

        let legacy = MuseTermKeychain.load(account: aiAPIKeyAccount)
        guard !legacy.isEmpty else { return "" }
        if MuseTermKeychain.save(
            legacy,
            account: aiAPIKeyAccount,
            serviceName: Self.aiKeychainServiceName
        ) {
            MuseTermKeychain.delete(account: aiAPIKeyAccount)
        }
        return legacy
    }

    func saveAIAPIKey(_ apiKey: String) -> Bool {
        let saved = MuseTermKeychain.save(
            apiKey,
            account: aiAPIKeyAccount,
            serviceName: Self.aiKeychainServiceName
        )
        objectWillChange.send()
        return saved && !loadAIAPIKey().isEmpty
    }

    func clearAIAPIKey() {
        MuseTermKeychain.delete(
            account: aiAPIKeyAccount,
            serviceName: Self.aiKeychainServiceName
        )
        MuseTermKeychain.delete(account: aiAPIKeyAccount)
        objectWillChange.send()
    }

    private var aiAPIKeyAccount: String {
        "ai-provider/\(aiProvider.rawValue)/api-key"
    }

    private func normalizeBuiltInAIProviderDefaults() {
        guard aiProvider != .custom else { return }
        let trimmedBaseURL = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if AIProviderKind.builtInDefaultBaseURLs.contains(trimmedBaseURL), !aiProvider.isBuiltInBaseURL(trimmedBaseURL) {
            aiBaseURL = aiProvider.defaultBaseURL
        }
        let trimmedModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if AIProviderKind.builtInDefaultModels.contains(trimmedModel), trimmedModel != aiProvider.defaultModel {
            aiModel = aiProvider.defaultModel
        }
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
