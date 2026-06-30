import Combine
import Foundation

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

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        user: String = "",
        port: Int = 22,
        identityFiles: [String] = [],
        jumpHosts: [SSHJumpHost] = [],
        extraOptions: [String] = [],
        startupCommands: [String] = []
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
            startupCommands: startupCommands.cleanedLineList()
        )
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
            extraOptions: profile.extraOptions
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
