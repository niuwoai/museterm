import Combine
import Foundation

enum TerminalEnvironmentKind: String, CaseIterable, Codable, Identifiable {
    case local
    case development
    case staging
    case production

    var id: String { rawValue }

    var name: String {
        L10n.string("environment.\(rawValue).name")
    }

    var shortName: String {
        L10n.string("environment.\(rawValue).short")
    }
}

enum SSHSafetyConfirmationPolicy: String, CaseIterable, Codable, Identifiable {
    case inherit
    case forceConfirm
    case disableConfirmations

    var id: String { rawValue }

    var name: String {
        L10n.string("ssh.safety_policy.\(rawValue).name")
    }

    var summary: String {
        L10n.string("ssh.safety_policy.\(rawValue).summary")
    }

    func resolves(globalValue: Bool) -> Bool {
        switch self {
        case .inherit:
            return globalValue
        case .forceConfirm:
            return true
        case .disableConfirmations:
            return false
        }
    }
}

struct SSHJumpHost: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var user: String
    var port: Int
    var identityFiles: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        user: String = "",
        port: Int = 22,
        identityFiles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
    }

    var normalized: SSHJumpHost {
        SSHJumpHost(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, 1), 65_535),
            identityFiles: identityFiles.cleanedPathList()
        )
    }

    var displayName: String {
        let clean = normalized
        if !clean.name.isEmpty { return clean.name }
        return clean.user.isEmpty ? clean.host : "\(clean.user)@\(clean.host)"
    }
}

struct SSHConnectionProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var user: String
    var port: Int
    var identityFiles: [String]
    var jumpHosts: [SSHJumpHost]
    var extraOptions: [String]
    var startupCommands: [String]
    var keepAliveEnabled: Bool
    var keepAliveIntervalSeconds: Int
    var keepAliveCountMax: Int
    var remoteShellIntegrationEnabled: Bool
    var environment: TerminalEnvironmentKind
    var safetyPolicy: SSHSafetyConfirmationPolicy

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        user: String = "",
        port: Int = 22,
        identityFiles: [String] = [],
        jumpHosts: [SSHJumpHost] = [],
        extraOptions: [String] = [],
        startupCommands: [String] = [],
        keepAliveEnabled: Bool = true,
        keepAliveIntervalSeconds: Int = 30,
        keepAliveCountMax: Int = 6,
        remoteShellIntegrationEnabled: Bool = true,
        environment: TerminalEnvironmentKind = .development,
        safetyPolicy: SSHSafetyConfirmationPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.jumpHosts = jumpHosts
        self.extraOptions = extraOptions
        self.startupCommands = startupCommands
        self.keepAliveEnabled = keepAliveEnabled
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.keepAliveCountMax = keepAliveCountMax
        self.remoteShellIntegrationEnabled = remoteShellIntegrationEnabled
        self.environment = environment
        self.safetyPolicy = safetyPolicy ?? Self.defaultSafetyPolicy(for: environment)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case user
        case port
        case identityFiles
        case jumpHosts
        case extraOptions
        case startupCommands
        case keepAliveEnabled
        case keepAliveIntervalSeconds
        case keepAliveCountMax
        case remoteShellIntegrationEnabled
        case environment
        case safetyPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        identityFiles = try container.decodeIfPresent([String].self, forKey: .identityFiles) ?? []
        jumpHosts = try container.decodeIfPresent([SSHJumpHost].self, forKey: .jumpHosts) ?? []
        extraOptions = try container.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        startupCommands = try container.decodeIfPresent([String].self, forKey: .startupCommands) ?? []
        keepAliveEnabled = try container.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? true
        keepAliveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveIntervalSeconds) ?? 30
        keepAliveCountMax = try container.decodeIfPresent(Int.self, forKey: .keepAliveCountMax) ?? 6
        remoteShellIntegrationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .remoteShellIntegrationEnabled
        ) ?? true
        environment = try container.decodeIfPresent(TerminalEnvironmentKind.self, forKey: .environment) ?? .development
        safetyPolicy = try container.decodeIfPresent(SSHSafetyConfirmationPolicy.self, forKey: .safetyPolicy)
            ?? Self.defaultSafetyPolicy(for: environment)
    }

    var normalized: SSHConnectionProfile {
        SSHConnectionProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, 1), 65_535),
            identityFiles: identityFiles.cleanedPathList(),
            jumpHosts: jumpHosts.map(\.normalized).filter { !$0.host.isEmpty },
            extraOptions: extraOptions.cleanedLineList(),
            startupCommands: startupCommands.cleanedLineList(),
            keepAliveEnabled: keepAliveEnabled,
            keepAliveIntervalSeconds: min(max(keepAliveIntervalSeconds, 5), 3_600),
            keepAliveCountMax: min(max(keepAliveCountMax, 1), 20),
            remoteShellIntegrationEnabled: remoteShellIntegrationEnabled,
            environment: environment,
            safetyPolicy: safetyPolicy
        )
    }

    static func defaultSafetyPolicy(for environment: TerminalEnvironmentKind) -> SSHSafetyConfirmationPolicy {
        environment == .production ? .forceConfirm : .inherit
    }

    var displayName: String {
        let clean = normalized
        if !clean.name.isEmpty { return clean.name }
        return clean.user.isEmpty ? clean.host : "\(clean.user)@\(clean.host)"
    }

    var target: String {
        let clean = normalized
        return clean.user.isEmpty ? clean.host : "\(clean.user)@\(clean.host)"
    }
}

final class SSHConnectionStore: ObservableObject {
    private static let key = "ssh.connectionProfiles.v1"
    private let defaults: UserDefaults

    @Published private(set) var profiles: [SSHConnectionProfile] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = Self.load(defaults: defaults)
    }

    func upsert(_ profile: SSHConnectionProfile) {
        let clean = profile.normalized
        guard !clean.host.isEmpty else { return }
        profiles.removeAll { $0.id == clean.id }
        profiles.append(clean)
        profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persist()
    }

    func delete(_ profile: SSHConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles.map(\.normalized)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(defaults: UserDefaults) -> [SSHConnectionProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SSHConnectionProfile].self, from: data) else {
            return []
        }
        return decoded.map(\.normalized).filter { !$0.host.isEmpty }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

struct SSHLaunchDescriptor {
    let executable: String
    let args: [String]
    let configURL: URL
    let startupCommands: [String]
}

enum SSHConfigMaterializer {
    static func descriptor(for profile: SSHConnectionProfile) throws -> SSHLaunchDescriptor {
        let clean = profile.normalized
        let directory = try configDirectory()
        let configURL = directory.appendingPathComponent("\(clean.id.uuidString).conf")
        let aliases = aliases(for: clean)
        let config = renderConfig(profile: clean, aliases: aliases)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        return SSHLaunchDescriptor(
            executable: "/usr/bin/ssh",
            args: ["-tt", "-F", configURL.path, aliases.target],
            configURL: configURL,
            startupCommands: clean.startupCommands
        )
    }

    static func renderConfig(profile: SSHConnectionProfile) -> String {
        renderConfig(profile: profile.normalized, aliases: aliases(for: profile.normalized))
    }

    private struct HostAliases {
        let target: String
        let jumps: [String]
    }

    private static func aliases(for profile: SSHConnectionProfile) -> HostAliases {
        let base = "museterm-\(profile.id.uuidString.lowercased())"
        return HostAliases(
            target: "\(base)-target",
            jumps: profile.jumpHosts.indices.map { "\(base)-jump-\($0 + 1)" }
        )
    }

    private static func renderConfig(profile: SSHConnectionProfile, aliases: HostAliases) -> String {
        var lines: [String] = [
            "# Generated by MuseTerm. Edit SSH hosts in the app instead of this file."
        ]

        for (index, jump) in profile.jumpHosts.enumerated() {
            lines.append(contentsOf: hostBlock(
                alias: aliases.jumps[index],
                host: jump.host,
                user: jump.user,
                port: jump.port,
                identityFiles: jump.identityFiles,
                proxyJump: index == 0 ? nil : aliases.jumps[index - 1],
                extraOptions: []
            ))
        }

        lines.append(contentsOf: hostBlock(
            alias: aliases.target,
            host: profile.host,
            user: profile.user,
            port: profile.port,
            identityFiles: profile.identityFiles,
            proxyJump: aliases.jumps.last,
            extraOptions: keepAliveOptions(for: profile) + profile.extraOptions
        ))

        return lines.joined(separator: "\n") + "\n"
    }

    private static func hostBlock(
        alias: String,
        host: String,
        user: String,
        port: Int,
        identityFiles: [String],
        proxyJump: String?,
        extraOptions: [String]
    ) -> [String] {
        var lines = [
            "",
            "Host \(alias)",
            "  HostName \(host)",
            "  Port \(port)"
        ]
        if !user.isEmpty {
            lines.append("  User \(user)")
        }
        for file in identityFiles {
            lines.append("  IdentityFile \(quote(expandTilde(file)))")
        }
        if !identityFiles.isEmpty {
            lines.append("  IdentitiesOnly yes")
        }
        if let proxyJump, !proxyJump.isEmpty {
            lines.append("  ProxyJump \(proxyJump)")
        }
        lines.append(contentsOf: extraOptions.map { "  \($0)" })
        return lines
    }

    private static func keepAliveOptions(for profile: SSHConnectionProfile) -> [String] {
        guard profile.keepAliveEnabled else { return [] }

        let manualOptions = Set(profile.extraOptions.compactMap { optionName($0) })
        var options: [String] = []
        if !manualOptions.contains("serveraliveinterval") {
            options.append("ServerAliveInterval \(profile.keepAliveIntervalSeconds)")
        }
        if !manualOptions.contains("serveralivecountmax") {
            options.append("ServerAliveCountMax \(profile.keepAliveCountMax)")
        }
        return options
    }

    private static func optionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased()
    }

    private static func configDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func expandTilde(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

extension Array where Element == String {
    func cleanedLineList() -> [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func cleanedPathList() -> [String] {
        Array(Set(cleanedLineList())).sorted()
    }
}
