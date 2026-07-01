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

enum SSHConnectionIssueKind: String, Equatable {
    case permissionDenied
    case hostKeyVerificationFailed
    case connectionTimedOut
    case connectionRefused
    case tooManyAuthenticationFailures
    case portForwardFailure

    var title: String {
        L10n.string("ssh.diagnostic.\(rawValue).title")
    }

    var summary: String {
        L10n.string("ssh.diagnostic.\(rawValue).summary")
    }

    var suggestion: String {
        L10n.string("ssh.diagnostic.\(rawValue).suggestion")
    }

    var allowsAutomaticReconnect: Bool {
        switch self {
        case .permissionDenied, .hostKeyVerificationFailed, .tooManyAuthenticationFailures:
            return false
        case .connectionTimedOut, .connectionRefused, .portForwardFailure:
            return true
        }
    }
}

enum SSHConnectionIssueClassifier {
    static func classify(_ text: String) -> SSHConnectionIssueKind? {
        let lowercased = text.lowercased()

        if lowercased.contains("too many authentication failures") {
            return .tooManyAuthenticationFailures
        }
        if lowercased.contains("permission denied") {
            return .permissionDenied
        }
        if lowercased.contains("host key verification failed")
            || lowercased.contains("remote host identification has changed") {
            return .hostKeyVerificationFailed
        }
        if lowercased.contains("connection timed out")
            || lowercased.contains("operation timed out") {
            return .connectionTimedOut
        }
        if lowercased.contains("connection refused") {
            return .connectionRefused
        }
        if lowercased.contains("cannot listen to port")
            || lowercased.contains("port forwarding failed")
            || lowercased.contains("channel_setup_fwd_listener")
            || lowercased.contains("administratively prohibited") {
            return .portForwardFailure
        }

        return nil
    }
}

enum SSHAutomaticReconnectDecision: Equatable {
    case reconnect(delaySeconds: Int)
    case suppress
    case exhausted
}

enum SSHReconnectPolicy {
    static func decision(
        profile: SSHConnectionProfile,
        issue: SSHConnectionIssueKind?,
        exitCode: Int32?,
        completedAttempts: Int
    ) -> SSHAutomaticReconnectDecision {
        let clean = profile.normalized
        guard clean.automaticReconnectEnabled,
              clean.automaticReconnectAttempts > 0 else {
            return .suppress
        }
        if exitCode == 0 {
            return .suppress
        }
        if issue?.allowsAutomaticReconnect == false {
            return .suppress
        }
        guard completedAttempts < clean.automaticReconnectAttempts else {
            return .exhausted
        }

        let multiplier = max(1, completedAttempts + 1)
        let delay = min(clean.automaticReconnectDelaySeconds * multiplier, 30)
        return .reconnect(delaySeconds: delay)
    }
}

enum SSHProfileSecurityWarningKind: String, Equatable {
    case agentForwarding
    case hostKeyCheckingDisabled
    case knownHostsDisabled

    var title: String {
        L10n.string("ssh.security_warning.\(rawValue).title")
    }

    var summary: String {
        L10n.string("ssh.security_warning.\(rawValue).summary")
    }
}

enum SSHProfileSecurityAnalyzer {
    nonisolated static func warningKinds(extraOptions: [String]) -> [SSHProfileSecurityWarningKind] {
        var warnings: [SSHProfileSecurityWarningKind] = []
        let options = extraOptions.compactMap(option)
        let truthyValues: Set<String> = ["yes", "true", "1"]
        let disabledHostKeyValues: Set<String> = ["no", "off", "false", "0"]
        let disabledKnownHostsValues: Set<String> = ["/dev/null", "none"]
        let knownHostsOptions: Set<String> = ["userknownhostsfile", "globalknownhostsfile"]

        if options.contains(where: { $0.name == "forwardagent" && truthyValues.contains($0.value) }) {
            warnings.append(.agentForwarding)
        }
        if options.contains(where: { $0.name == "stricthostkeychecking" && disabledHostKeyValues.contains($0.value) }) {
            warnings.append(.hostKeyCheckingDisabled)
        }
        if options.contains(where: { knownHostsOptions.contains($0.name) && disabledKnownHostsValues.contains($0.value) }) {
            warnings.append(.knownHostsDisabled)
        }

        return warnings
    }

    private nonisolated static func option(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        guard parts.count == 2 else { return nil }
        return (
            String(parts[0]).lowercased(),
            String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

enum SSHProfilePreflightIssueKind: String, Equatable {
    case duplicatePortForwardListener
    case identityFileUnavailable
    case jumpIdentityFileUnavailable

    var title: String {
        L10n.string("ssh.preflight_issue.\(rawValue).title")
    }

    func summary(detail: String) -> String {
        L10n.format("ssh.preflight_issue.\(rawValue).summary", detail)
    }
}

struct SSHProfilePreflightIssue: Identifiable, Equatable {
    let kind: SSHProfilePreflightIssueKind
    let detail: String

    var id: String {
        "\(kind.rawValue)-\(detail)"
    }
}

enum SSHProfilePreflightAnalyzer {
    static func issues(
        for profile: SSHConnectionProfile,
        fileManager: FileManager = .default
    ) -> [SSHProfilePreflightIssue] {
        duplicateForwardIssues(for: profile.portForwards)
            + identityIssues(for: profile, fileManager: fileManager)
    }

    private static func duplicateForwardIssues(
        for forwards: [SSHPortForward]
    ) -> [SSHProfilePreflightIssue] {
        var seen: Set<String> = []
        var duplicates: [String] = []

        for forward in forwards {
            let key = listenerKey(for: forward)
            guard !key.isEmpty else { continue }
            if !seen.insert(key).inserted, !duplicates.contains(key) {
                duplicates.append(key)
            }
        }

        return duplicates.map {
            SSHProfilePreflightIssue(kind: .duplicatePortForwardListener, detail: $0)
        }
    }

    private static func listenerKey(for forward: SSHPortForward) -> String {
        let bindPort = min(max(forward.bindPort, 1), 65_535)
        let bindHost = forward.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let side = forward.kind == .remote ? "remote" : "local"
        let host = bindHost.isEmpty ? "*" : bindHost
        return "\(side) \(host):\(bindPort)"
    }

    private static func identityIssues(
        for profile: SSHConnectionProfile,
        fileManager: FileManager
    ) -> [SSHProfilePreflightIssue] {
        var issues: [SSHProfilePreflightIssue] = []

        for path in profile.identityFiles.cleanedPathList() where !identityFileExists(path, fileManager: fileManager) {
            issues.append(SSHProfilePreflightIssue(kind: .identityFileUnavailable, detail: path))
        }

        for jump in profile.jumpHosts {
            for path in jump.identityFiles.cleanedPathList() where !identityFileExists(path, fileManager: fileManager) {
                let detail = "\(jumpDisplayName(jump)): \(path)"
                issues.append(SSHProfilePreflightIssue(kind: .jumpIdentityFileUnavailable, detail: detail))
            }
        }

        return issues
    }

    private static func jumpDisplayName(_ jump: SSHJumpHost) -> String {
        let name = jump.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let user = jump.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = jump.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    private static func identityFileExists(_ path: String, fileManager: FileManager) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains("%") else { return true }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
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

enum SSHPortForwardKind: String, CaseIterable, Codable, Identifiable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }
}

struct SSHPortForward: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: SSHPortForwardKind
    var bindHost: String
    var bindPort: Int
    var destinationHost: String
    var destinationPort: Int

    init(
        id: UUID = UUID(),
        kind: SSHPortForwardKind = .local,
        bindHost: String = "",
        bindPort: Int = 0,
        destinationHost: String = "",
        destinationPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    var normalized: SSHPortForward {
        SSHPortForward(
            id: id,
            kind: kind,
            bindHost: bindHost.trimmingCharacters(in: .whitespacesAndNewlines),
            bindPort: min(max(bindPort, 1), 65_535),
            destinationHost: destinationHost.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationPort: min(max(destinationPort, 1), 65_535)
        )
    }

    var isUsable: Bool {
        let clean = normalized
        guard clean.bindPort > 0 else { return false }
        if clean.kind == .dynamic { return true }
        return !clean.destinationHost.isEmpty && clean.destinationPort > 0
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
    var portForwards: [SSHPortForward]
    var extraOptions: [String]
    var startupCommands: [String]
    var keepAliveEnabled: Bool
    var keepAliveIntervalSeconds: Int
    var keepAliveCountMax: Int
    var connectionReuseEnabled: Bool
    var connectionReusePersistMinutes: Int
    var automaticReconnectEnabled: Bool
    var automaticReconnectAttempts: Int
    var automaticReconnectDelaySeconds: Int
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
        portForwards: [SSHPortForward] = [],
        extraOptions: [String] = [],
        startupCommands: [String] = [],
        keepAliveEnabled: Bool = true,
        keepAliveIntervalSeconds: Int = 30,
        keepAliveCountMax: Int = 6,
        connectionReuseEnabled: Bool = true,
        connectionReusePersistMinutes: Int = 10,
        automaticReconnectEnabled: Bool = true,
        automaticReconnectAttempts: Int = 3,
        automaticReconnectDelaySeconds: Int = 3,
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
        self.portForwards = portForwards
        self.extraOptions = extraOptions
        self.startupCommands = startupCommands
        self.keepAliveEnabled = keepAliveEnabled
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.keepAliveCountMax = keepAliveCountMax
        self.connectionReuseEnabled = connectionReuseEnabled
        self.connectionReusePersistMinutes = connectionReusePersistMinutes
        self.automaticReconnectEnabled = automaticReconnectEnabled
        self.automaticReconnectAttempts = automaticReconnectAttempts
        self.automaticReconnectDelaySeconds = automaticReconnectDelaySeconds
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
        case portForwards
        case extraOptions
        case startupCommands
        case keepAliveEnabled
        case keepAliveIntervalSeconds
        case keepAliveCountMax
        case connectionReuseEnabled
        case connectionReusePersistMinutes
        case automaticReconnectEnabled
        case automaticReconnectAttempts
        case automaticReconnectDelaySeconds
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
        portForwards = try container.decodeIfPresent([SSHPortForward].self, forKey: .portForwards) ?? []
        extraOptions = try container.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        startupCommands = try container.decodeIfPresent([String].self, forKey: .startupCommands) ?? []
        keepAliveEnabled = try container.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? true
        keepAliveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveIntervalSeconds) ?? 30
        keepAliveCountMax = try container.decodeIfPresent(Int.self, forKey: .keepAliveCountMax) ?? 6
        connectionReuseEnabled = try container.decodeIfPresent(Bool.self, forKey: .connectionReuseEnabled) ?? true
        connectionReusePersistMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .connectionReusePersistMinutes
        ) ?? 10
        automaticReconnectEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticReconnectEnabled) ?? true
        automaticReconnectAttempts = try container.decodeIfPresent(Int.self, forKey: .automaticReconnectAttempts) ?? 3
        automaticReconnectDelaySeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .automaticReconnectDelaySeconds
        ) ?? 3
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
            portForwards: portForwards.map(\.normalized).filter(\.isUsable),
            extraOptions: extraOptions.cleanedLineList(),
            startupCommands: startupCommands.cleanedLineList(),
            keepAliveEnabled: keepAliveEnabled,
            keepAliveIntervalSeconds: min(max(keepAliveIntervalSeconds, 5), 3_600),
            keepAliveCountMax: min(max(keepAliveCountMax, 1), 20),
            connectionReuseEnabled: connectionReuseEnabled,
            connectionReusePersistMinutes: min(max(connectionReusePersistMinutes, 1), 1_440),
            automaticReconnectEnabled: automaticReconnectEnabled,
            automaticReconnectAttempts: min(max(automaticReconnectAttempts, 0), 20),
            automaticReconnectDelaySeconds: min(max(automaticReconnectDelaySeconds, 1), 120),
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

    var routeSummary: String {
        let clean = normalized
        let nodes = [L10n.string("ssh.route.local")]
            + clean.jumpHosts.map(\.displayName)
            + [clean.target]
        return nodes.joined(separator: " -> ")
    }

    var securityWarningKinds: [SSHProfileSecurityWarningKind] {
        SSHProfileSecurityAnalyzer.warningKinds(extraOptions: normalized.extraOptions)
    }

    var preflightIssues: [SSHProfilePreflightIssue] {
        SSHProfilePreflightAnalyzer.issues(for: self)
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
        let controlPathTemplate = directory.appendingPathComponent("cm-%C").path
        let config = renderConfig(profile: clean, aliases: aliases, controlPathTemplate: controlPathTemplate)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        return SSHLaunchDescriptor(
            executable: "/usr/bin/ssh",
            args: ["-tt", "-F", configURL.path, aliases.target],
            configURL: configURL,
            startupCommands: clean.startupCommands
        )
    }

    static func renderConfig(profile: SSHConnectionProfile) -> String {
        let clean = profile.normalized
        return renderConfig(
            profile: clean,
            aliases: aliases(for: clean),
            controlPathTemplate: "~/.ssh/museterm-cm-%C"
        )
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

    private static func renderConfig(
        profile: SSHConnectionProfile,
        aliases: HostAliases,
        controlPathTemplate: String
    ) -> String {
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
            extraOptions: connectionReuseOptions(for: profile, controlPathTemplate: controlPathTemplate)
                + keepAliveOptions(for: profile)
                + portForwardOptions(for: profile)
                + profile.extraOptions
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

    private static func connectionReuseOptions(
        for profile: SSHConnectionProfile,
        controlPathTemplate: String
    ) -> [String] {
        guard profile.connectionReuseEnabled else { return [] }

        let manualOptions = Set(profile.extraOptions.compactMap { optionName($0) })
        var options: [String] = []
        if !manualOptions.contains("controlmaster") {
            options.append("ControlMaster auto")
        }
        if !manualOptions.contains("controlpersist") {
            options.append("ControlPersist \(profile.connectionReusePersistMinutes)m")
        }
        if !manualOptions.contains("controlpath") {
            options.append("ControlPath \(quote(controlPathTemplate))")
        }
        return options
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

    private static func portForwardOptions(for profile: SSHConnectionProfile) -> [String] {
        let forwards = profile.portForwards.map(\.normalized).filter(\.isUsable)
        guard !forwards.isEmpty else { return [] }

        let manualOptions = Set(profile.extraOptions.compactMap { optionName($0) })
        var options: [String] = []
        if !manualOptions.contains("exitonforwardfailure") {
            options.append("ExitOnForwardFailure yes")
        }

        for forward in forwards {
            let listen = listenSpec(host: forward.bindHost, port: forward.bindPort)
            switch forward.kind {
            case .local:
                options.append("LocalForward \(listen) \(forward.destinationHost):\(forward.destinationPort)")
            case .remote:
                options.append("RemoteForward \(listen) \(forward.destinationHost):\(forward.destinationPort)")
            case .dynamic:
                options.append("DynamicForward \(listen)")
            }
        }
        return options
    }

    private static func listenSpec(host: String, port: Int) -> String {
        host.isEmpty ? "\(port)" : "\(host):\(port)"
    }

    private static func optionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first?.lowercased()
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
