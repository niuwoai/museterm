import Combine
import Foundation

/// 本地终端 Profile 使用的 shell 类型。`.login` = 跟随系统登录 shell（getpwuid），
/// `.custom` = 使用 `customShellPath` 指定的可执行文件。
enum ProfileShellKind: String, Codable, CaseIterable, Identifiable {
    case login
    case zsh
    case bash
    case fish
    case custom

    var id: String { rawValue }

    var titleKey: String { "profile.shell.\(rawValue)" }
}

/// Profile 的 prompt 风格。`.system` = 不改用户 PS1（默认行为）；`.custom` = 用户按所选
/// shell 的原生语法自填。其余为内置预设，由 shell 集成脚本按环境变量分派实现。
enum PromptStyle: String, Codable, CaseIterable, Identifiable {
    case system
    case minimal
    case path
    case git
    case twoLine
    case custom

    var id: String { rawValue }

    var titleKey: String { "profile.prompt.\(rawValue)" }
}

/// 一个本地终端 Profile：定义 shell、PS1、环境变量、启动命令、默认工作目录。
struct TerminalProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var shell: ProfileShellKind
    var customShellPath: String
    var promptStyle: PromptStyle
    var customPrompt: String
    var environment: [String: String]
    var startupCommands: [String]
    var workingDirectory: String
    var isDefault: Bool
    var isFavorite: Bool
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        shell: ProfileShellKind = .login,
        customShellPath: String = "",
        promptStyle: PromptStyle = .system,
        customPrompt: String = "",
        environment: [String: String] = [:],
        startupCommands: [String] = [],
        workingDirectory: String = "",
        isDefault: Bool = false,
        isFavorite: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.shell = shell
        self.customShellPath = customShellPath
        self.promptStyle = promptStyle
        self.customPrompt = customPrompt
        self.environment = environment
        self.startupCommands = startupCommands
        self.workingDirectory = workingDirectory
        self.isDefault = isDefault
        self.isFavorite = isFavorite
        self.sortIndex = sortIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shell, customShellPath, promptStyle, customPrompt
        case environment, startupCommands, workingDirectory
        case isDefault, isFavorite, sortIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        shell = try container.decodeIfPresent(ProfileShellKind.self, forKey: .shell) ?? .login
        customShellPath = try container.decodeIfPresent(String.self, forKey: .customShellPath) ?? ""
        promptStyle = try container.decodeIfPresent(PromptStyle.self, forKey: .promptStyle) ?? .system
        customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        startupCommands = try container.decodeIfPresent([String].self, forKey: .startupCommands) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("profile.untitled") : trimmed
    }

    /// 归一化：修剪空白、清理环境变量与启动命令，钳制字段。
    var normalized: TerminalProfile {
        var cleanEnvironment: [String: String] = [:]
        for (rawKey, rawValue) in environment {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("=") else { continue }
            cleanEnvironment[key] = rawValue
        }
        return TerminalProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            shell: shell,
            customShellPath: customShellPath.trimmingCharacters(in: .whitespacesAndNewlines),
            promptStyle: promptStyle,
            customPrompt: customPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: cleanEnvironment,
            startupCommands: startupCommands
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            isDefault: isDefault,
            isFavorite: isFavorite,
            sortIndex: sortIndex
        )
    }

    /// 是否等价于"系统默认行为"（可复用预热 tab、行为零变化）。
    var isSystemEquivalent: Bool {
        let clean = normalized
        return clean.shell == .login
            && clean.promptStyle == .system
            && clean.environment.isEmpty
            && clean.startupCommands.isEmpty
            && clean.workingDirectory.isEmpty
    }
}

/// Profile 列表持久化，完全复刻 SSHConnectionStore 的 JSON→UserDefaults 模式。
final class TerminalProfileStore: ObservableObject {
    // 单一主窗口 → 单一逻辑存储。侧栏与设置窗共享同一实例，改动即时互相反映。
    static let shared = TerminalProfileStore()
    private static let key = "terminal.localProfiles.v1"
    private let defaults: UserDefaults

    @Published private(set) var profiles: [TerminalProfile] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = Self.load(defaults: defaults)
        ensureDefaultExists()
    }

    /// 当前默认 profile；若列表意外为空则返回一个内存中的系统默认。
    var defaultProfile: TerminalProfile {
        profiles.first { $0.isDefault } ?? profiles.first ?? Self.seededDefault()
    }

    func profile(id: UUID) -> TerminalProfile? {
        profiles.first { $0.id == id }
    }

    func upsert(_ profile: TerminalProfile) {
        let clean = profile.normalized
        if let index = profiles.firstIndex(where: { $0.id == clean.id }) {
            profiles[index] = clean
        } else {
            var appended = clean
            appended.sortIndex = (profiles.map(\.sortIndex).max() ?? 0) + 1
            profiles.append(appended)
        }
        normalizeDefaultFlag(preferring: clean.isDefault ? clean.id : nil)
        sortAndPersist()
    }

    func delete(_ profile: TerminalProfile) {
        // 默认 profile 不可删除。
        guard !isEffectiveDefault(profile.id) else { return }
        profiles.removeAll { $0.id == profile.id }
        ensureDefaultExists()
        sortAndPersist()
    }

    func setDefault(_ profile: TerminalProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        normalizeDefaultFlag(preferring: profile.id)
        sortAndPersist()
    }

    func toggleFavorite(_ profile: TerminalProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isFavorite.toggle()
        sortAndPersist()
    }

    private func isEffectiveDefault(_ id: UUID) -> Bool {
        defaultProfile.id == id
    }

    /// 保证恰有一个 profile 被标记为默认。
    private func normalizeDefaultFlag(preferring preferredID: UUID?) {
        guard !profiles.isEmpty else { return }
        let targetID = preferredID
            ?? profiles.first(where: { $0.isDefault })?.id
            ?? profiles[0].id
        for index in profiles.indices {
            profiles[index].isDefault = profiles[index].id == targetID
        }
    }

    private func ensureDefaultExists() {
        if profiles.isEmpty {
            profiles = [Self.seededDefault()]
        } else if !profiles.contains(where: { $0.isDefault }) {
            profiles[0].isDefault = true
        }
    }

    private func sortAndPersist() {
        // 默认置顶，其余按收藏、sortIndex、名称排序。
        profiles.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profiles.map(\.normalized))
            defaults.set(data, forKey: Self.key)
        } catch {
            NSLog("MuseTerm: failed to persist terminal profiles: %@", String(describing: error))
        }
    }

    private static func load(defaults: UserDefaults) -> [TerminalProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TerminalProfile].self, from: data) else {
            return []
        }
        return decoded.map(\.normalized)
    }

    private static func seededDefault() -> TerminalProfile {
        TerminalProfile(
            name: L10n.string("profile.default.name"),
            shell: .login,
            promptStyle: .system,
            isDefault: true,
            sortIndex: 0
        )
    }
}
