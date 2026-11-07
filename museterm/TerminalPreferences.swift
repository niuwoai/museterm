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
    static let magpieLocalGatewayAPIKey = "magpie-museterm"

    case openAI
    case anthropic
    case google
    case azureOpenAI
    case openRouter
    case someIM
    case ollama
    case llamaServer
    case magpie
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
        case .magpie: return ""
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
        case .magpie: return "http://127.0.0.1:3425/v1"
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
        case .ollama, .llamaServer, .magpie: return true
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

    enum Keys {
        static let skin = "terminal.skin"
        static let fontFamily = "terminal.fontFamily"
        // 旧版单回退字体键，仅用于迁移与回滚兼容
        static let fallbackFontFamily = "terminal.fallbackFontFamily"
        static let fallbackFontFamilies = "terminal.fallbackFontFamilies"
        static let fontSize = "terminal.fontSize"
        static let lineHeight = "terminal.lineHeight"
        static let glassEnabled = "terminal.glassEnabled"
        static let glassMaterial = "terminal.glassMaterial"
        static let glassOpacity = "terminal.glassOpacity"
        static let windowOpacity = "terminal.windowOpacity"
        static let terminalOpacity = "terminal.terminalOpacity"
        static let tintOpacity = "terminal.tintOpacity"
        static let glow = "terminal.glow"
        static let optionAsMeta = "terminal.optionAsMeta"
        static let mouseReporting = "terminal.mouseReporting"
        static let copyOnSelect = "terminal.copyOnSelect"
        static let openWebImagesInViewer = "terminal.openWebImagesInViewer"
        static let scrollbackLines = "terminal.scrollbackLines"
        static let imageCacheMegabytes = "terminal.imageCacheMegabytes"
        static let showsTabList = "terminal.showsTabList"
        static let sidebarExpandedWidth = "terminal.sidebarExpandedWidth"
        static let sidebarSectionOrder = "sidebar.sectionOrder"
        static let hiddenSidebarSections = "sidebar.hiddenSections"
        static let sidebarSectionExpansionOverrides = "sidebar.sectionExpansionOverrides"
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
        static let toolBridgeWritesEnabled = "tools.writeEnabled"
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
    static let minimumImageCacheMegabytes = TerminalGraphicsPolicy.minimumCacheMegabytes
    static let defaultImageCacheMegabytes = TerminalGraphicsPolicy.defaultCacheMegabytes
    static let maximumImageCacheMegabytes = TerminalGraphicsPolicy.maximumCacheMegabytes
    static let imageCacheStepMegabytes = TerminalGraphicsPolicy.cacheStepMegabytes
    /// 侧栏里实际显示的分区，按用户排好的顺序，去掉隐藏的。
    var visibleSidebarSections: [SidebarSectionKind] {
        sidebarSectionOrder.filter { !hiddenSidebarSections.contains($0) }
    }

    func isSidebarSectionVisible(_ kind: SidebarSectionKind) -> Bool {
        !hiddenSidebarSections.contains(kind)
    }

    func setSidebarSection(_ kind: SidebarSectionKind, visible: Bool) {
        if visible {
            hiddenSidebarSections.remove(kind)
        } else {
            hiddenSidebarSections.insert(kind)
        }
    }

    /// 分区当前是否展开。没有保存过的分区用上线前的默认展开状态。
    func isSidebarSectionExpanded(_ kind: SidebarSectionKind) -> Bool {
        sidebarSectionExpansionOverrides.contains(kind) != SidebarSectionKind.defaultExpanded(kind)
    }

    /// 记住一次手动展开或收起。结果与默认一致时不再保存，避免无谓写入。
    func setSidebarSection(_ kind: SidebarSectionKind, expanded: Bool) {
        let overridden = expanded != SidebarSectionKind.defaultExpanded(kind)
        if overridden {
            sidebarSectionExpansionOverrides.insert(kind)
        } else {
            sidebarSectionExpansionOverrides.remove(kind)
        }
    }

    /// 把分区在顺序里上移或下移一格。两端再移就停在原地。
    func moveSidebarSection(_ kind: SidebarSectionKind, direction: Int) {
        guard direction != 0,
              let index = sidebarSectionOrder.firstIndex(of: kind) else { return }
        let destination = index + (direction > 0 ? 1 : -1)
        guard sidebarSectionOrder.indices.contains(destination) else { return }
        var reordered = sidebarSectionOrder
        reordered.swapAt(index, destination)
        sidebarSectionOrder = reordered
    }

    static let minimumSidebarExpandedWidth = 220.0
    static let defaultSidebarExpandedWidth = 220.0
    static let maximumSidebarExpandedWidth = 420.0

    @Published var skin: TerminalVisualSkin { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
    @Published var fontFamily: String { didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) } }
    /// 按顺序生效的回退字体；靠前的字体先被 Core Text 级联命中。
    @Published var fallbackFontFamilies: [String] {
        didSet {
            let sanitized = TerminalFontResolver.sanitizedFallbackFamilies(fallbackFontFamilies)
            // 在 didSet 内赋值不会再次触发 didSet，这里只是把内存值收敛到规范形式
            if sanitized != fallbackFontFamilies {
                fallbackFontFamilies = sanitized
            }
            defaults.set(sanitized, forKey: Keys.fallbackFontFamilies)
            // 旧版本只认单个回退字体，回写首项以便降级安装时仍有合理表现
            defaults.set(sanitized.first ?? "", forKey: Keys.fallbackFontFamily)
        }
    }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    @Published var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: Keys.lineHeight) } }
    @Published var glassEnabled: Bool { didSet { defaults.set(glassEnabled, forKey: Keys.glassEnabled) } }
    @Published var glassMaterial: GlassMaterial { didSet { defaults.set(glassMaterial.rawValue, forKey: Keys.glassMaterial) } }
    @Published var glassOpacity: Double { didSet { defaults.set(glassOpacity, forKey: Keys.glassOpacity) } }
    @Published var windowOpacity: Double { didSet { defaults.set(windowOpacity, forKey: Keys.windowOpacity) } }
    @Published var terminalOpacity: Double { didSet { defaults.set(terminalOpacity, forKey: Keys.terminalOpacity) } }
    @Published var tintOpacity: Double { didSet { defaults.set(tintOpacity, forKey: Keys.tintOpacity) } }
    @Published var glow: Double { didSet { defaults.set(glow, forKey: Keys.glow) } }
    @Published var optionAsMeta: Bool { didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) } }
    @Published var mouseReporting: Bool { didSet { defaults.set(mouseReporting, forKey: Keys.mouseReporting) } }
    @Published var copyOnSelect: Bool { didSet { defaults.set(copyOnSelect, forKey: Keys.copyOnSelect) } }
    @Published var openWebImagesInViewer: Bool {
        didSet { defaults.set(openWebImagesInViewer, forKey: Keys.openWebImagesInViewer) }
    }
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
    @Published var imageCacheMegabytes: Int {
        didSet {
            let normalized = Self.clampedImageCacheMegabytes(imageCacheMegabytes)
            guard imageCacheMegabytes == normalized else {
                imageCacheMegabytes = normalized
                return
            }
            defaults.set(imageCacheMegabytes, forKey: Keys.imageCacheMegabytes)
        }
    }
    @Published var showsTabList: Bool { didSet { defaults.set(showsTabList, forKey: Keys.showsTabList) } }
    /// 侧栏可排序分区的显示顺序。写入时收敛成一份完整、无重复的顺序。
    @Published var sidebarSectionOrder: [SidebarSectionKind] {
        didSet {
            let normalized = SidebarSectionKind.normalizedOrder(sidebarSectionOrder.map(\.rawValue))
            guard sidebarSectionOrder == normalized else {
                sidebarSectionOrder = normalized
                return
            }
            defaults.set(normalized.map(\.rawValue), forKey: Keys.sidebarSectionOrder)
        }
    }
    /// 被用户隐藏的分区。顺序里仍然保留它们，重新打开时回到原来的位置。
    @Published var hiddenSidebarSections: Set<SidebarSectionKind> {
        didSet {
            defaults.set(hiddenSidebarSections.map(\.rawValue).sorted(), forKey: Keys.hiddenSidebarSections)
        }
    }
    /// 和默认展开状态不同的分区。默认展开的被收起、默认收起的被展开，都记在这里；没动过的分区不写入。
    @Published var sidebarSectionExpansionOverrides: Set<SidebarSectionKind> {
        didSet {
            defaults.set(sidebarSectionExpansionOverrides.map(\.rawValue).sorted(), forKey: Keys.sidebarSectionExpansionOverrides)
        }
    }
    @Published var sidebarExpandedWidth: Double {
        didSet {
            let normalized = Self.clampedSidebarExpandedWidth(sidebarExpandedWidth)
            guard sidebarExpandedWidth == normalized else {
                sidebarExpandedWidth = normalized
                return
            }
            defaults.set(sidebarExpandedWidth, forKey: Keys.sidebarExpandedWidth)
        }
    }
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
    @Published var agentMonitoringEnabled: Bool { didSet { defaults.set(agentMonitoringEnabled, forKey: "agent.monitoringEnabled") } }
    @Published var notifyAgentAttention: Bool { didSet { defaults.set(notifyAgentAttention, forKey: "notifications.agentAttention") } }
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
    @Published var toolBridgeWritesEnabled: Bool { didSet { defaults.set(toolBridgeWritesEnabled, forKey: Keys.toolBridgeWritesEnabled) } }
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
        skin = TerminalVisualSkin(rawValue: defaults.string(forKey: Keys.skin) ?? "") ?? .midnight
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "SF Mono"
        fallbackFontFamilies = TerminalPreferences.loadFallbackFontFamilies(from: defaults)
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 14
        lineHeight = defaults.object(forKey: Keys.lineHeight) as? Double ?? 1.08
        glassEnabled = defaults.object(forKey: Keys.glassEnabled) as? Bool ?? true
        glassMaterial = GlassMaterial(rawValue: defaults.string(forKey: Keys.glassMaterial) ?? "") ?? .underWindow
        glassOpacity = defaults.object(forKey: Keys.glassOpacity) as? Double ?? 0.72
        windowOpacity = defaults.object(forKey: Keys.windowOpacity) as? Double ?? 0.72
        terminalOpacity = defaults.object(forKey: Keys.terminalOpacity) as? Double ?? 0.86
        tintOpacity = defaults.object(forKey: Keys.tintOpacity) as? Double ?? 0.20
        glow = defaults.object(forKey: Keys.glow) as? Double ?? 0.24
        optionAsMeta = defaults.object(forKey: Keys.optionAsMeta) as? Bool ?? true
        mouseReporting = defaults.object(forKey: Keys.mouseReporting) as? Bool ?? true
        copyOnSelect = defaults.object(forKey: Keys.copyOnSelect) as? Bool ?? true
        openWebImagesInViewer = defaults.object(forKey: Keys.openWebImagesInViewer) as? Bool ?? true
        scrollbackLines = Self.clampedScrollbackLines(
            defaults.object(forKey: Keys.scrollbackLines) as? Int ?? Self.defaultScrollbackLines
        )
        imageCacheMegabytes = Self.clampedImageCacheMegabytes(
            defaults.object(forKey: Keys.imageCacheMegabytes) as? Int ?? Self.defaultImageCacheMegabytes
        )
        showsTabList = defaults.object(forKey: Keys.showsTabList) as? Bool ?? true
        sidebarSectionOrder = SidebarSectionKind.normalizedOrder(
            defaults.stringArray(forKey: Keys.sidebarSectionOrder) ?? []
        )
        hiddenSidebarSections = Set(
            (defaults.stringArray(forKey: Keys.hiddenSidebarSections) ?? [])
                .compactMap(SidebarSectionKind.init(rawValue:))
        )
        sidebarSectionExpansionOverrides = Set(
            (defaults.stringArray(forKey: Keys.sidebarSectionExpansionOverrides) ?? [])
                .compactMap(SidebarSectionKind.init(rawValue:))
        )
        sidebarExpandedWidth = Self.clampedSidebarExpandedWidth(
            defaults.object(forKey: Keys.sidebarExpandedWidth) as? Double ?? Self.defaultSidebarExpandedWidth
        )
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
        agentMonitoringEnabled = defaults.object(forKey: "agent.monitoringEnabled") as? Bool ?? true
        notifyAgentAttention = defaults.object(forKey: "notifications.agentAttention") as? Bool ?? true
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
        toolBridgeWritesEnabled = defaults.object(forKey: Keys.toolBridgeWritesEnabled) as? Bool ?? false
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

    static func clampedImageCacheMegabytes(_ value: Int) -> Int {
        TerminalGraphicsPolicy.clampedCacheMegabytes(value)
    }

    static func clampedSidebarExpandedWidth(_ value: Double) -> Double {
        min(max(value, minimumSidebarExpandedWidth), maximumSidebarExpandedWidth)
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
            fallbackFamilies: fallbackFontFamilies,
            size: CGFloat(fontSize)
        )
    }

    static let defaultFallbackFontFamilies = ["PingFang SC"]

    /// 读取回退字体列表：优先新版数组键，其次迁移旧版单字符串键，最后落到默认值。
    /// 数组键存在但为空表示用户主动清空，需要如实保留。
    static func loadFallbackFontFamilies(from defaults: UserDefaults) -> [String] {
        if let stored = defaults.array(forKey: Keys.fallbackFontFamilies) as? [String] {
            return TerminalFontResolver.sanitizedFallbackFamilies(stored)
        }
        if let legacy = defaults.string(forKey: Keys.fallbackFontFamily) {
            return TerminalFontResolver.sanitizedFallbackFamilies([legacy])
        }
        return defaultFallbackFontFamilies
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

    var hasExplicitAIConfiguration: Bool {
        defaults.object(forKey: Keys.aiProvider) != nil
            || defaults.object(forKey: Keys.aiModel) != nil
            || defaults.object(forKey: Keys.aiBaseURL) != nil
            || hasAIAPIKey
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

    /// 回退字体数量上限，避免级联链过长拖慢字形查找。
    static let maximumFallbackFamilies = 8

    /// 规范化回退字体列表：去空白、去空项、按大小写不敏感去重并保序，最后截断到上限。
    static func sanitizedFallbackFamilies(_ families: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for family in families {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maximumFallbackFamilies { break }
        }
        return result
    }

    /// 按列表顺序构建 Core Text 级联字体；未安装的字体会被跳过而不是中断整条链。
    static func font(primaryFamily: String, fallbackFamilies: [String], size: CGFloat) -> NSFont {
        let base = font(named: primaryFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        let descriptors = sanitizedFallbackFamilies(fallbackFamilies)
            .compactMap { font(named: $0, size: size)?.fontDescriptor }

        guard !descriptors.isEmpty else { return base }

        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: descriptors
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func font(named family: String, size: CGFloat) -> NSFont? {
        NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }
}
