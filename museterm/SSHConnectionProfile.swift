import Combine
import Darwin
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

enum SSHRouteDiagnosticStepKind: Equatable {
    case target
    case jump(index: Int)
    case unknown
}

struct SSHRouteDiagnosticContext: Equatable {
    let kind: SSHRouteDiagnosticStepKind
    let displayName: String
    let host: String?
    let port: Int?
    let evidence: String?
    let routeSummary: String

    var message: String {
        let evidenceMessage = evidence.map { L10n.format("ssh.route_diagnostic.evidence", $0) }
        let routeMessage = L10n.format("ssh.route_diagnostic.route", routeSummary)
        let headline: String
        switch kind {
        case .target:
            headline = L10n.format(
                "ssh.route_diagnostic.target",
                displayName,
                host ?? displayName,
                port ?? 22
            )
        case .jump(let index):
            headline = L10n.format(
                "ssh.route_diagnostic.jump",
                index,
                displayName,
                host ?? displayName,
                port ?? 22
            )
        case .unknown:
            headline = L10n.string("ssh.route_diagnostic.unknown")
        }
        return ([headline, routeMessage] + [evidenceMessage].compactMap { $0 }).joined(separator: "\n")
    }
}

struct SSHRouteProbeCommand: Equatable {
    let title: String
    let command: String
}

struct SSHRouteProbeGuide: Equatable {
    let commands: [SSHRouteProbeCommand]

    var message: String {
        guard !commands.isEmpty else { return "" }
        let lines = commands.enumerated().map { index, command in
            L10n.format("ssh.route_probe.command", index + 1, command.title, command.command)
        }
        return ([L10n.string("ssh.route_probe.title")] + lines).joined(separator: "\n")
    }
}

enum SSHRouteDiagnosticProbeKind: String, Equatable {
    case dnsLookup
    case tcpPort
    case generatedConfig
    case verboseRoute
}

struct SSHRouteDiagnosticPlanStep: Equatable {
    let kind: SSHRouteDiagnosticProbeKind
    let title: String
    let command: String
    let routeStepKind: SSHRouteDiagnosticStepKind?
    let host: String?
    let port: Int?
    let alias: String?
    let includeInFailureGuide: Bool

    func interpretResult(exitCode: Int32?, output: String) -> SSHRouteDiagnosticStepResult {
        SSHRouteDiagnosticStepResultInterpreter.interpret(step: self, exitCode: exitCode, output: output)
    }
}

struct SSHRouteDiagnosticPlan: Equatable {
    let routeSummary: String
    let steps: [SSHRouteDiagnosticPlanStep]

    var failureGuide: SSHRouteProbeGuide {
        SSHRouteProbeGuide(
            commands: steps
                .filter(\.includeInFailureGuide)
                .map { SSHRouteProbeCommand(title: $0.title, command: $0.command) }
        )
    }
}

enum SSHRouteProbeGuideBuilder {
    private struct RouteStep {
        let kind: SSHRouteDiagnosticStepKind
        let displayName: String
        let host: String
        let port: Int
        let alias: String
    }

    static func guide(
        for profile: SSHConnectionProfile,
        issue: SSHConnectionIssueKind
    ) -> SSHRouteProbeGuide? {
        plan(for: profile, issue: issue)?.failureGuide
    }

    static func plan(
        for profile: SSHConnectionProfile,
        issue: SSHConnectionIssueKind
    ) -> SSHRouteDiagnosticPlan? {
        let clean = profile.normalized
        guard !clean.host.isEmpty else { return nil }
        let routeSteps = routeSteps(for: clean)
        guard let firstStep = routeSteps.first else { return nil }

        var steps: [SSHRouteDiagnosticPlanStep] = [
            SSHRouteDiagnosticPlanStep(
                kind: .dnsLookup,
                title: L10n.format("ssh.route_probe.dns", firstStep.host),
                command: dnsLookupCommand(host: firstStep.host),
                routeStepKind: firstStep.kind,
                host: firstStep.host,
                port: nil,
                alias: firstStep.alias,
                includeInFailureGuide: true
            ),
            SSHRouteDiagnosticPlanStep(
                kind: .tcpPort,
                title: L10n.format("ssh.route_probe.port", firstStep.host, firstStep.port),
                command: localPortProbeCommand(host: firstStep.host, port: firstStep.port),
                routeStepKind: firstStep.kind,
                host: firstStep.host,
                port: firstStep.port,
                alias: firstStep.alias,
                includeInFailureGuide: true
            ),
            SSHRouteDiagnosticPlanStep(
                kind: .generatedConfig,
                title: L10n.string("ssh.route_probe.config"),
                command: generatedConfigCommand(for: clean),
                routeStepKind: .target,
                host: clean.host,
                port: clean.port,
                alias: SSHConfigMaterializer.targetAlias(for: clean),
                includeInFailureGuide: true
            )
        ]

        if issue != .hostKeyVerificationFailed {
            steps.append(contentsOf: routeSteps.map { step in
                SSHRouteDiagnosticPlanStep(
                    kind: .verboseRoute,
                    title: verboseTitle(for: step),
                    command: verboseRouteCommand(for: clean, alias: step.alias),
                    routeStepKind: step.kind,
                    host: step.host,
                    port: step.port,
                    alias: step.alias,
                    includeInFailureGuide: true
                )
            })
        }

        return SSHRouteDiagnosticPlan(routeSummary: clean.routeSummary, steps: steps)
    }

    private static func routeSteps(for profile: SSHConnectionProfile) -> [RouteStep] {
        let base = "museterm-\(profile.id.uuidString.lowercased())"
        let jumps = profile.jumpHosts.enumerated().map { index, jump in
            RouteStep(
                kind: .jump(index: index + 1),
                displayName: jump.displayName,
                host: jump.host,
                port: jump.port,
                alias: "\(base)-jump-\(index + 1)"
            )
        }
        let target = RouteStep(
            kind: .target,
            displayName: profile.displayName,
            host: profile.host,
            port: profile.port,
            alias: "\(base)-target"
        )
        return jumps + [target]
    }

    private static func dnsLookupCommand(host: String) -> String {
        "dscacheutil -q host -a name \(shellArgument(host)) || nslookup \(shellArgument(host))"
    }

    private static func localPortProbeCommand(host: String, port: Int) -> String {
        "nc -vz -w 5 \(shellArgument(host)) \(port)"
    }

    private static func generatedConfigCommand(for profile: SSHConnectionProfile) -> String {
        let config = SSHConfigMaterializer.configFileURL(for: profile).path
        let alias = SSHConfigMaterializer.targetAlias(for: profile)
        return "ssh -G -F \(shellArgument(config)) \(shellArgument(alias))"
    }

    private static func verboseRouteCommand(for profile: SSHConnectionProfile, alias: String) -> String {
        let config = SSHConfigMaterializer.configFileURL(for: profile).path
        return "ssh -vvv -F \(shellArgument(config)) \(shellArgument(alias)) true"
    }

    private static func verboseTitle(for step: RouteStep) -> String {
        switch step.kind {
        case .jump(let index):
            return L10n.format("ssh.route_probe.verbose_jump", index, step.displayName)
        case .target:
            return L10n.format("ssh.route_probe.verbose_target", step.displayName)
        case .unknown:
            return L10n.string("ssh.route_probe.verbose")
        }
    }

    private nonisolated static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SSHRouteDiagnosticAnalyzer {
    private struct RouteStep {
        let kind: SSHRouteDiagnosticStepKind
        let displayName: String
        let host: String
        let port: Int
        let aliases: [String]
    }

    static func context(
        for profile: SSHConnectionProfile,
        diagnosticText: String
    ) -> SSHRouteDiagnosticContext? {
        let clean = profile.normalized
        guard !clean.host.isEmpty else { return nil }
        let steps = routeSteps(for: clean)
        let endpoint = endpointMentioned(in: diagnosticText)
        let evidence = evidenceLine(in: diagnosticText)

        if let endpoint,
           let step = steps.first(where: { matches(endpoint: endpoint, step: $0) }) {
            return SSHRouteDiagnosticContext(
                kind: step.kind,
                displayName: step.displayName,
                host: step.host,
                port: step.port,
                evidence: endpoint.evidence ?? evidence,
                routeSummary: clean.routeSummary
            )
        }

        if clean.jumpHosts.isEmpty, let target = steps.last {
            return SSHRouteDiagnosticContext(
                kind: target.kind,
                displayName: target.displayName,
                host: target.host,
                port: target.port,
                evidence: evidence,
                routeSummary: clean.routeSummary
            )
        }

        return SSHRouteDiagnosticContext(
            kind: .unknown,
            displayName: "",
            host: nil,
            port: nil,
            evidence: evidence,
            routeSummary: clean.routeSummary
        )
    }

    private static func routeSteps(for profile: SSHConnectionProfile) -> [RouteStep] {
        let base = "museterm-\(profile.id.uuidString.lowercased())"
        let jumps = profile.jumpHosts.enumerated().map { index, jump in
            RouteStep(
                kind: .jump(index: index + 1),
                displayName: jump.displayName,
                host: jump.host,
                port: jump.port,
                aliases: ["\(base)-jump-\(index + 1)"]
            )
        }
        let target = RouteStep(
            kind: .target,
            displayName: profile.displayName,
            host: profile.host,
            port: profile.port,
            aliases: ["\(base)-target"]
        )
        return jumps + [target]
    }

    private static func matches(endpoint: (host: String, port: Int?, evidence: String?), step: RouteStep) -> Bool {
        let endpointHost = normalizedHost(endpoint.host)
        let hostMatches = normalizedHost(step.host) == endpointHost
            || step.aliases.contains(where: { normalizedHost($0) == endpointHost })
            || normalizedHost(step.displayName) == endpointHost
        guard hostMatches else { return false }
        if let port = endpoint.port {
            return port == step.port
        }
        return true
    }

    private static func endpointMentioned(in text: String) -> (host: String, port: Int?, evidence: String?)? {
        for line in text.components(separatedBy: .newlines).reversed() {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if let endpoint = connectToHostEndpoint(in: clean) {
                return (endpoint.host, endpoint.port, clean)
            }
            if let endpoint = resolvingHostnameEndpoint(in: clean) {
                return (endpoint, nil, clean)
            }
        }
        return nil
    }

    private static func connectToHostEndpoint(in line: String) -> (host: String, port: Int)? {
        let pattern = #"connect to host\s+([^\s]+)\s+port\s+([0-9]+)"#
        guard let match = firstRegexMatch(pattern: pattern, in: line) else { return nil }
        guard match.count >= 3, let port = Int(match[2]) else { return nil }
        return (match[1], port)
    }

    private static func resolvingHostnameEndpoint(in line: String) -> String? {
        let pattern = #"Could not resolve hostname\s+([^:\s]+)"#
        guard let match = firstRegexMatch(pattern: pattern, in: line), match.count >= 2 else { return nil }
        return match[1]
    }

    private static func evidenceLine(in text: String) -> String? {
        text.components(separatedBy: .newlines)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func normalizedHost(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n."))
            .lowercased()
    }
}

struct SSHConnectionHostKeyRepairGuide: Equatable {
    let knownHostsTarget: String
    let removalCommand: String
    let offendingLocation: String?

    var message: String {
        if let offendingLocation, !offendingLocation.isEmpty {
            return L10n.format(
                "ssh.diagnostic.hostKeyVerificationFailed.repair_known_location",
                knownHostsTarget,
                offendingLocation,
                removalCommand
            )
        }
        return L10n.format(
            "ssh.diagnostic.hostKeyVerificationFailed.repair_unknown_location",
            knownHostsTarget,
            removalCommand
        )
    }
}

enum SSHConnectionIssueRepairGuide {
    static func message(
        for issue: SSHConnectionIssueKind,
        profile: SSHConnectionProfile,
        diagnosticText: String
    ) -> String? {
        switch issue {
        case .hostKeyVerificationFailed:
            return hostKeyGuide(for: profile, diagnosticText: diagnosticText)?.message
        case .permissionDenied, .connectionTimedOut, .connectionRefused, .tooManyAuthenticationFailures, .portForwardFailure:
            return nil
        }
    }

    static func hostKeyGuide(
        for profile: SSHConnectionProfile,
        diagnosticText: String
    ) -> SSHConnectionHostKeyRepairGuide? {
        let clean = profile.normalized
        guard !clean.host.isEmpty else { return nil }
        let target = knownHostsTarget(host: clean.host, port: clean.port)
        let offendingLocation = offendingKnownHostsLocation(in: diagnosticText)
        return SSHConnectionHostKeyRepairGuide(
            knownHostsTarget: target,
            removalCommand: hostKeyRemovalCommand(
                target: target,
                knownHostsFile: offendingLocation.flatMap(knownHostsFilePath)
            ),
            offendingLocation: offendingLocation
        )
    }

    private nonisolated static func hostKeyRemovalCommand(target: String, knownHostsFile: String?) -> String {
        if let knownHostsFile, !knownHostsFile.isEmpty {
            return "ssh-keygen -f \(shellArgument(knownHostsFile)) -R \(shellArgument(target))"
        }
        return "ssh-keygen -R \(shellArgument(target))"
    }

    private static func knownHostsTarget(host: String, port: Int) -> String {
        let cleanHost = normalizedKnownHostsHost(host)
        return port == 22 ? cleanHost : "[\(cleanHost)]:\(port)"
    }

    private static func normalizedKnownHostsHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let closingBracket = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
        }
        return trimmed
    }

    private nonisolated static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func offendingKnownHostsLocation(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let original = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let markerRange = original.range(of: " key in ", options: .caseInsensitive) else { continue }
            let location = original[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !location.isEmpty {
                return location
            }
        }
        return nil
    }

    private nonisolated static func knownHostsFilePath(from offendingLocation: String) -> String? {
        let trimmed = offendingLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let lineSeparator = trimmed.lastIndex(of: ":"),
              trimmed[trimmed.index(after: lineSeparator)...].allSatisfy(\.isNumber) else {
            return trimmed
        }
        let path = String(trimmed[..<lineSeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

enum SSHAutomaticReconnectDecision: Equatable {
    case reconnect(delaySeconds: Int)
    case suppress
    case exhausted
}

enum SSHDisconnectReasonKind: String, Equatable {
    case cleanExit
    case authenticationOrSecurityStopped
    case remoteClosedConnection
    case networkInterrupted
    case unknownFailure

    var allowsAutomaticReconnect: Bool {
        switch self {
        case .networkInterrupted, .unknownFailure:
            return true
        case .cleanExit, .authenticationOrSecurityStopped, .remoteClosedConnection:
            return false
        }
    }

    var title: String {
        L10n.string("ssh.disconnect_reason.\(rawValue)")
    }
}

enum SSHDisconnectReasonClassifier {
    static func classify(
        issue: SSHConnectionIssueKind?,
        exitCode: Int32?,
        diagnosticText: String
    ) -> SSHDisconnectReasonKind {
        if exitCode == 0 {
            return .cleanExit
        }
        if issue?.allowsAutomaticReconnect == false {
            return .authenticationOrSecurityStopped
        }
        let normalized = diagnosticText.lowercased()
        if containsAny(
            normalized,
            [
                "broken pipe",
                "connection reset by peer",
                "operation timed out",
                "connection timed out",
                "network is unreachable",
                "no route to host",
                "connection refused"
            ]
        ) || issue?.allowsAutomaticReconnect == true {
            return .networkInterrupted
        }
        if containsAny(
            normalized,
            [
                "connection closed by remote host",
                "closed by remote host",
                "kex_exchange_identification: connection closed",
                "connection to ",
                "received disconnect"
            ]
        ) {
            return .remoteClosedConnection
        }
        return .unknownFailure
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

enum SSHReconnectPolicy {
    static func decision(
        profile: SSHConnectionProfile,
        issue: SSHConnectionIssueKind?,
        exitCode: Int32?,
        completedAttempts: Int,
        disconnectReason: SSHDisconnectReasonKind? = nil
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
        if let disconnectReason, !disconnectReason.allowsAutomaticReconnect {
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

        if options.contains(where: { option in
            option.name == "forwardagent"
                && option.valueTokens.first.map(truthyValues.contains) == true
        }) {
            warnings.append(.agentForwarding)
        }
        if options.contains(where: { option in
            option.name == "stricthostkeychecking"
                && option.valueTokens.first.map(disabledHostKeyValues.contains) == true
        }) {
            warnings.append(.hostKeyCheckingDisabled)
        }
        if options.contains(where: { option in
            knownHostsOptions.contains(option.name)
                && option.valueTokens.contains(where: { disabledKnownHostsValues.contains($0) })
        }) {
            warnings.append(.knownHostsDisabled)
        }

        return warnings
    }

    private nonisolated static func option(_ line: String) -> (name: String, value: String, valueTokens: [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        guard parts.count == 2 else { return nil }
        let value = normalizedOptionValue(String(parts[1]))
        return (
            String(parts[0]).lowercased(),
            value,
            value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        )
    }

    private nonisolated static func normalizedOptionValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { rawToken in
                String(rawToken)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .lowercased()
            }
            .joined(separator: " ")
    }
}

enum SSHProfilePreflightIssueKind: String, Equatable {
    case duplicatePortForwardListener
    case identityFileUnavailable
    case jumpIdentityFileUnavailable
    case identityFilePermissionsTooOpen
    case jumpIdentityFilePermissionsTooOpen

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

struct SSHProfileHealthSummary: Equatable {
    let preflightIssues: [SSHProfilePreflightIssue]
    let securityWarnings: [SSHProfileSecurityWarningKind]

    var preflightIssueCount: Int {
        preflightIssues.count
    }

    var securityWarningCount: Int {
        securityWarnings.count
    }

    var hasAttentionItems: Bool {
        preflightIssueCount > 0 || securityWarningCount > 0
    }

    var tooltip: String {
        let sections = [
            summaryLine,
            preflightLine,
            securityLine
        ].compactMap { $0 }
        return sections.joined(separator: "\n")
    }

    private var summaryLine: String {
        if preflightIssueCount > 0, securityWarningCount > 0 {
            return L10n.format("ssh.health.summary.mixed", preflightIssueCount, securityWarningCount)
        }
        if preflightIssueCount > 0 {
            return L10n.format("ssh.health.summary.preflight", preflightIssueCount)
        }
        if securityWarningCount > 0 {
            return L10n.format("ssh.health.summary.security", securityWarningCount)
        }
        return L10n.string("ssh.health.summary.clean")
    }

    private var preflightLine: String? {
        guard !preflightIssues.isEmpty else { return nil }
        return preflightIssues
            .prefix(3)
            .map { $0.kind.summary(detail: $0.detail) }
            .joined(separator: "\n")
    }

    private var securityLine: String? {
        guard !securityWarnings.isEmpty else { return nil }
        return securityWarnings
            .prefix(3)
            .map(\.summary)
            .joined(separator: "\n")
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

        for path in profile.identityFiles.cleanedPathList() {
            guard identityFileExists(path, fileManager: fileManager) else {
                issues.append(SSHProfilePreflightIssue(kind: .identityFileUnavailable, detail: path))
                continue
            }
            if identityFilePermissionsAreTooOpen(path, fileManager: fileManager) {
                issues.append(SSHProfilePreflightIssue(kind: .identityFilePermissionsTooOpen, detail: chmodDetail(for: path)))
            }
        }

        for jump in profile.jumpHosts {
            for path in jump.identityFiles.cleanedPathList() {
                let label = jumpDisplayName(jump)
                guard identityFileExists(path, fileManager: fileManager) else {
                    let detail = "\(label): \(path)"
                    issues.append(SSHProfilePreflightIssue(kind: .jumpIdentityFileUnavailable, detail: detail))
                    continue
                }
                if identityFilePermissionsAreTooOpen(path, fileManager: fileManager) {
                    let detail = "\(label): \(chmodDetail(for: path))"
                    issues.append(SSHProfilePreflightIssue(kind: .jumpIdentityFilePermissionsTooOpen, detail: detail))
                }
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

    private static func identityFilePermissionsAreTooOpen(_ path: String, fileManager: FileManager) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("%") else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard let attributes = try? fileManager.attributesOfItem(atPath: expanded),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 != 0
    }

    private static func chmodDetail(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed) -> chmod 600 \(TerminalShellArgumentEscaper.shellArgument(trimmed))"
    }
}

enum SSHConfigImportError: LocalizedError {
    case missingDefaultConfig

    var errorDescription: String? {
        switch self {
        case .missingDefaultConfig:
            return L10n.string("ssh.import.error.missing_config")
        }
    }
}

enum OpenSSHConfigImporter {
    private struct ParsedLine {
        var key: String
        var args: [String]
        var originalOption: String
    }

    private struct HostBlock {
        var aliases: [String]
        var options: [ParsedLine]
    }

    static func profiles(fromFileAt url: URL, fileManager: FileManager = .default) throws -> [SSHConnectionProfile] {
        let text = try expandedConfigText(from: url, fileManager: fileManager)
        return profiles(from: text)
    }

    static func profiles(from text: String) -> [SSHConnectionProfile] {
        var importedProfiles: [SSHConnectionProfile] = []
        let blocks = hostBlocks(from: text)
        for block in blocks {
            importedProfiles.append(contentsOf: profiles(from: block, allBlocks: blocks))
        }
        return importedProfiles
    }

    private static func expandedConfigText(
        from url: URL,
        fileManager: FileManager,
        visitedPaths: Set<String> = []
    ) throws -> String {
        let standardizedPath = (url.path as NSString).standardizingPath
        guard !visitedPaths.contains(standardizedPath) else { return "" }
        let nextVisited = visitedPaths.union([standardizedPath])
        let text = try String(contentsOfFile: standardizedPath, encoding: .utf8)
        let baseURL = URL(fileURLWithPath: standardizedPath).deletingLastPathComponent()
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            guard let parsed = parseLine(rawLine),
                  parsed.key.caseInsensitiveCompare("include") == .orderedSame else {
                lines.append(rawLine)
                continue
            }

            for pattern in parsed.args {
                let matches = includeURLs(
                    matching: pattern,
                    relativeTo: baseURL,
                    fileManager: fileManager
                )
                for includeURL in matches {
                    let includedText = try expandedConfigText(
                        from: includeURL,
                        fileManager: fileManager,
                        visitedPaths: nextVisited
                    )
                    if !includedText.isEmpty {
                        lines.append(includedText)
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func hostBlocks(from text: String) -> [HostBlock] {
        var blocks: [HostBlock] = []
        var current: HostBlock?
        var isInsideMatchBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            guard let parsed = parseLine(rawLine) else { continue }
            let key = parsed.key.lowercased()

            if key == "host" {
                if let current {
                    blocks.append(current)
                }
                isInsideMatchBlock = false
                current = HostBlock(aliases: parsed.args, options: [])
                continue
            }

            if key == "match" {
                if let current {
                    blocks.append(current)
                }
                current = nil
                isInsideMatchBlock = true
                continue
            }

            guard !isInsideMatchBlock else { continue }
            current?.options.append(parsed)
        }

        if let current {
            blocks.append(current)
        }
        return blocks
    }

    private static func profiles(from block: HostBlock, allBlocks: [HostBlock]) -> [SSHConnectionProfile] {
        let aliases = uniqueImportableAliases(in: block.aliases)
        return aliases.compactMap { alias in
            profile(
                from: block,
                alias: alias,
                defaultOptions: defaultOptions(for: alias, in: allBlocks)
            )
        }
    }

    private static func profile(
        from block: HostBlock,
        alias: String,
        defaultOptions: [ParsedLine]
    ) -> SSHConnectionProfile? {
        guard isImportableHostAlias(alias) else { return nil }

        var host = ""
        var user = ""
        var port = 22
        var identityFiles: [String] = []
        var jumpHosts: [SSHJumpHost] = []
        var portForwards: [SSHPortForward] = []
        var extraOptions: [String] = []
        var keepAliveEnabled = true
        var keepAliveIntervalSeconds = 30
        var keepAliveCountMax = 6
        var connectionReuseEnabled = true
        var connectionReusePersistMinutes = 10

        for option in mergedOptions(defaultOptions: defaultOptions, blockOptions: block.options) {
            let key = option.key.lowercased()
            switch key {
            case "hostname":
                host = option.args.first.map { expandHostNameTokens($0, alias: alias) } ?? host
            case "user":
                user = option.args.first ?? user
            case "port":
                port = option.args.first.flatMap(Int.init) ?? port
            case "identityfile":
                identityFiles.append(contentsOf: option.args)
            case "proxyjump":
                jumpHosts = parseProxyJump(option.args.first)
            case "localforward":
                if let forward = parseForward(kind: .local, args: option.args) {
                    portForwards.append(forward)
                }
            case "remoteforward":
                if let forward = parseForward(kind: .remote, args: option.args) {
                    portForwards.append(forward)
                }
            case "dynamicforward":
                if let forward = parseDynamicForward(args: option.args) {
                    portForwards.append(forward)
                }
            case "serveraliveinterval":
                if let value = option.args.first.flatMap(Int.init) {
                    keepAliveEnabled = value > 0
                    keepAliveIntervalSeconds = max(5, value)
                }
            case "serveralivecountmax":
                if let value = option.args.first.flatMap(Int.init) {
                    keepAliveCountMax = max(1, value)
                }
            case "controlmaster":
                if let value = option.args.first?.lowercased() {
                    connectionReuseEnabled = !["no", "false", "0"].contains(value)
                }
            case "controlpersist":
                if let value = option.args.first?.lowercased() {
                    if ["no", "false", "0"].contains(value) {
                        connectionReuseEnabled = false
                    } else if let minutes = parseDurationMinutes(value) {
                        connectionReusePersistMinutes = minutes
                    }
                }
            default:
                extraOptions.append(option.originalOption)
            }
        }

        let cleanHost = host.isEmpty ? alias : host
        let expandedIdentityFiles = identityFiles.map {
            expandConfigTokens($0, alias: alias, host: cleanHost, user: user)
        }
        return SSHConnectionProfile(
            name: alias,
            host: cleanHost,
            user: user,
            port: port,
            identityFiles: expandedIdentityFiles,
            jumpHosts: jumpHosts,
            portForwards: portForwards,
            extraOptions: extraOptions,
            keepAliveEnabled: keepAliveEnabled,
            keepAliveIntervalSeconds: keepAliveIntervalSeconds,
            keepAliveCountMax: keepAliveCountMax,
            connectionReuseEnabled: connectionReuseEnabled,
            connectionReusePersistMinutes: connectionReusePersistMinutes
        ).normalized
    }

    private static func defaultOptions(for alias: String, in blocks: [HostBlock]) -> [ParsedLine] {
        blocks
            .filter { isPatternDefaultBlock($0, matching: alias) }
            .flatMap(\.options)
    }

    private static func isPatternDefaultBlock(_ block: HostBlock, matching alias: String) -> Bool {
        let aliases = block.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !aliases.isEmpty, uniqueImportableAliases(in: aliases).isEmpty else { return false }
        var hasPositiveMatch = false
        for pattern in aliases {
            if pattern.hasPrefix("!") {
                let negated = String(pattern.dropFirst())
                if hostPatternMatches(negated, alias) {
                    return false
                }
                continue
            }
            if hostPatternMatches(pattern, alias) {
                hasPositiveMatch = true
            }
        }
        return hasPositiveMatch
    }

    private nonisolated static func hostPatternMatches(_ pattern: String, _ host: String) -> Bool {
        let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanPattern.isEmpty, !cleanHost.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: cleanPattern)
        let regexPattern = "^" + escaped
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return cleanHost.range(of: regexPattern, options: .regularExpression) != nil
    }

    private nonisolated static func mergedOptions(defaultOptions: [ParsedLine], blockOptions: [ParsedLine]) -> [ParsedLine] {
        let explicitSingletonKeys = Set(
            blockOptions
                .map { $0.key.lowercased() }
                .filter { !isMultiValueOption($0) }
        )
        let filteredDefaults = defaultOptions.filter { option in
            let key = option.key.lowercased()
            return isMultiValueOption(key) || !explicitSingletonKeys.contains(key)
        }
        return filteredDefaults + blockOptions
    }

    private nonisolated static func isMultiValueOption(_ key: String) -> Bool {
        switch key {
        case "identityfile", "localforward", "remoteforward", "dynamicforward":
            return true
        default:
            return false
        }
    }

    private nonisolated static func expandHostNameTokens(_ value: String, alias: String) -> String {
        expandConfigTokens(value, alias: alias, host: alias, user: "")
    }

    private nonisolated static func expandConfigTokens(
        _ value: String,
        alias: String,
        host: String,
        user: String
    ) -> String {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            guard let token = iterator.next() else {
                result.append(character)
                continue
            }
            switch token {
            case "%":
                result.append("%")
            case "h", "n":
                result.append(token == "h" ? cleanHost : cleanAlias)
            case "r":
                result.append(cleanUser)
            case "d":
                result.append(NSHomeDirectory())
            default:
                result.append("%")
                result.append(token)
            }
        }
        return result
    }

    private static func uniqueImportableAliases(in aliases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isImportableHostAlias(trimmed), seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func parseLine(_ rawLine: String) -> ParsedLine? {
        let tokens = tokens(from: rawLine)
        guard !tokens.isEmpty else { return nil }

        var key = tokens[0]
        var args = Array(tokens.dropFirst())
        if let separator = key.firstIndex(of: "=") {
            let rawKey = String(key[..<separator])
            let value = String(key[key.index(after: separator)...])
            key = rawKey
            if !value.isEmpty {
                args.insert(value, at: 0)
            }
        } else if let firstArg = args.first {
            if firstArg == "=" {
                args.removeFirst()
            } else if firstArg.hasPrefix("=") {
                let value = String(firstArg.dropFirst())
                args.removeFirst()
                if !value.isEmpty {
                    args.insert(value, at: 0)
                }
            }
        }

        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return nil }
        return ParsedLine(
            key: cleanKey,
            args: args,
            originalOption: ([cleanKey] + args).joined(separator: " ")
        )
    }

    private static func tokens(from line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character == "#" {
                break
            }

            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func includeURLs(
        matching pattern: String,
        relativeTo baseURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let expanded = pattern.expandingTildePath()
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = baseURL.appendingPathComponent(expanded).path
        }
        let standardizedPath = (absolutePath as NSString).standardizingPath
        let matches = wildcardPaths(matching: standardizedPath, fileManager: fileManager)
        return matches
            .filter { path in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func wildcardPaths(matching pattern: String, fileManager: FileManager) -> [String] {
        guard pattern.contains("*") || pattern.contains("?") else { return [pattern] }
        let components = (pattern as NSString).pathComponents
        guard let first = components.first else { return [] }
        let initialURL = URL(fileURLWithPath: first)
        let remainingComponents = Array(components.dropFirst())
        return wildcardPaths(
            baseURLs: [initialURL],
            remainingComponents: remainingComponents,
            fileManager: fileManager
        )
    }

    private static func wildcardPaths(
        baseURLs: [URL],
        remainingComponents: [String],
        fileManager: FileManager
    ) -> [String] {
        guard let component = remainingComponents.first else {
            return baseURLs.map(\.path)
        }

        let nextComponents = Array(remainingComponents.dropFirst())
        let nextBaseURLs: [URL]
        if component.contains("*") || component.contains("?") {
            nextBaseURLs = baseURLs.flatMap { baseURL in
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: baseURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsPackageDescendants]
                ) else {
                    return [URL]()
                }
                return contents.filter { wildcard(component, matches: $0.lastPathComponent) }
            }
        } else {
            nextBaseURLs = baseURLs.map { $0.appendingPathComponent(component) }
        }

        return wildcardPaths(
            baseURLs: nextBaseURLs,
            remainingComponents: nextComponents,
            fileManager: fileManager
        )
    }

    private static func wildcard(_ pattern: String, matches value: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }

    private static func isImportableHostAlias(_ alias: String) -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains("*")
            && !trimmed.contains("?")
            && !trimmed.hasPrefix("!")
    }

    private static func parseProxyJump(_ rawValue: String?) -> [SSHJumpHost] {
        guard let rawValue else { return [] }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }
        return trimmed
            .split(separator: ",")
            .compactMap { parseJumpHost(String($0)) }
    }

    private static func parseJumpHost(_ rawValue: String) -> SSHJumpHost? {
        let spec = parseUserHostPort(rawValue)
        guard !spec.host.isEmpty else { return nil }
        return SSHJumpHost(host: spec.host, user: spec.user, port: spec.port)
    }

    private static func parseForward(kind: SSHPortForwardKind, args: [String]) -> SSHPortForward? {
        guard args.count >= 2,
              let listen = parseListenSpec(args[0]),
              let destination = parseDestinationSpec(args[1]) else {
            return nil
        }
        return SSHPortForward(
            kind: kind,
            bindHost: listen.host,
            bindPort: listen.port,
            destinationHost: destination.host,
            destinationPort: destination.port
        )
    }

    private static func parseDynamicForward(args: [String]) -> SSHPortForward? {
        guard let first = args.first,
              let listen = parseListenSpec(first) else {
            return nil
        }
        return SSHPortForward(kind: .dynamic, bindHost: listen.host, bindPort: listen.port)
    }

    private static func parseListenSpec(_ rawValue: String) -> (host: String, port: Int)? {
        parseEndpointSpec(rawValue, allowsPortOnly: true)
    }

    private static func parseDestinationSpec(_ rawValue: String) -> (host: String, port: Int)? {
        parseEndpointSpec(rawValue, allowsPortOnly: false)
    }

    private static func parseEndpointSpec(_ rawValue: String, allowsPortOnly: Bool) -> (host: String, port: Int)? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let remainder = String(trimmed[trimmed.index(after: closingBracket)...])
            guard !host.isEmpty,
                  remainder.hasPrefix(":"),
                  let port = Int(remainder.dropFirst()) else {
                return nil
            }
            return (host, port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if allowsPortOnly, parts.count == 1, let port = Int(parts[0]) {
            return ("", port)
        }
        guard parts.count >= 2,
              let port = Int(parts.last ?? "") else {
            return nil
        }
        let host = parts.dropLast().joined(separator: ":")
        guard !host.isEmpty || allowsPortOnly else { return nil }
        return (host, port)
    }

    private static func parseUserHostPort(_ rawValue: String) -> (user: String, host: String, port: Int) {
        var user = ""
        var hostAndPort = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = hostAndPort.firstIndex(of: "@") {
            user = String(hostAndPort[..<separator])
            hostAndPort = String(hostAndPort[hostAndPort.index(after: separator)...])
        }

        var host = hostAndPort
        var port = 22
        if hostAndPort.hasPrefix("[") {
            guard let bracketed = parseBracketedHostPort(hostAndPort) else {
                return (user, "", port)
            }
            host = bracketed.host
            port = bracketed.port
        } else if hostAndPort.filter({ $0 == ":" }).count == 1,
                  let separator = hostAndPort.lastIndex(of: ":"),
                  let parsedPort = Int(hostAndPort[hostAndPort.index(after: separator)...]) {
            host = String(hostAndPort[..<separator])
            port = parsedPort
        }
        return (user, host, port)
    }

    private static func parseBracketedHostPort(_ rawValue: String) -> (host: String, port: Int)? {
        guard rawValue.hasPrefix("["),
              let closingBracket = rawValue.firstIndex(of: "]") else {
            return nil
        }
        let host = String(rawValue[rawValue.index(after: rawValue.startIndex)..<closingBracket])
        guard !host.isEmpty else { return nil }
        let remainder = String(rawValue[rawValue.index(after: closingBracket)...])
        if remainder.isEmpty {
            return (host, 22)
        }
        guard remainder.hasPrefix(":"),
              let port = Int(remainder.dropFirst()) else {
            return nil
        }
        return (host, port)
    }

    private static func parseDurationMinutes(_ rawValue: String) -> Int? {
        if rawValue == "yes" { return nil }
        let digits = rawValue.prefix { $0.isNumber }
        guard let value = Int(digits), value > 0 else { return nil }
        let suffix = rawValue.dropFirst(digits.count).lowercased()
        switch suffix {
        case "h":
            return value * 60
        case "m":
            return value
        case "s":
            return max(1, Int(ceil(Double(value) / 60.0)))
        default:
            return max(1, Int(ceil(Double(value) / 60.0)))
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

enum SSHPortForwardKind: String, CaseIterable, Codable, Identifiable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        L10n.string("ssh.port_forward.kind.\(rawValue)")
    }
}

struct SSHPortForward: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: SSHPortForwardKind
    var bindHost: String
    var bindPort: Int
    var destinationHost: String
    var destinationPort: Int

    nonisolated init(
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

    var listenEndpoint: String {
        let clean = normalized
        let host = clean.bindHost.isEmpty ? L10n.string("ssh.port_forward.localhost") : clean.bindHost
        return Self.displayEndpoint(host: host, port: clean.bindPort)
    }

    var destinationEndpoint: String? {
        let clean = normalized
        guard clean.kind != .dynamic else { return nil }
        return Self.displayEndpoint(host: clean.destinationHost, port: clean.destinationPort)
    }

    var localAccessURLString: String? {
        let clean = normalized
        switch clean.kind {
        case .local:
            let scheme = clean.destinationPort == 443 || clean.bindPort == 443 ? "https" : "http"
            return "\(scheme)://\(clean.browserHost):\(clean.bindPort)"
        case .dynamic:
            return "socks5://\(clean.browserHost):\(clean.bindPort)"
        case .remote:
            return nil
        }
    }

    var accessLine: String? {
        guard let localAccessURLString else { return nil }
        switch normalized.kind {
        case .local:
            return L10n.format("ssh.port_forward.access.local", localAccessURLString)
        case .dynamic:
            return L10n.format("ssh.port_forward.access.dynamic", localAccessURLString)
        case .remote:
            return nil
        }
    }

    var accessEntry: SSHPortForwardAccessEntry? {
        guard let localAccessURLString else { return nil }
        return SSHPortForwardAccessEntry(kind: normalized.kind, urlString: localAccessURLString)
    }

    var summaryLine: String {
        let clean = normalized
        switch clean.kind {
        case .local:
            return L10n.format(
                "ssh.port_forward.summary.local",
                clean.listenEndpoint,
                clean.destinationEndpoint ?? ""
            )
        case .remote:
            return L10n.format(
                "ssh.port_forward.summary.remote",
                clean.listenEndpoint,
                clean.destinationEndpoint ?? ""
            )
        case .dynamic:
            return L10n.format("ssh.port_forward.summary.dynamic", clean.listenEndpoint)
        }
    }

    var previewTargetText: String {
        let clean = normalized
        switch clean.kind {
        case .local, .remote:
            return clean.destinationEndpoint ?? ""
        case .dynamic:
            return L10n.string("ssh.port_forward.preview.socks")
        }
    }

    var previewAccessText: String {
        localAccessURLString ?? L10n.string("ssh.port_forward.preview.no_local_entry")
    }

    var editorLineText: String {
        let clean = normalized
        let listen = clean.bindHost.isEmpty ? "\(clean.bindPort)" : Self.displayEndpoint(host: clean.bindHost, port: clean.bindPort)
        switch clean.kind {
        case .local:
            return "local|\(listen)|\(Self.displayEndpoint(host: clean.destinationHost, port: clean.destinationPort))"
        case .remote:
            return "remote|\(listen)|\(Self.displayEndpoint(host: clean.destinationHost, port: clean.destinationPort))"
        case .dynamic:
            return "dynamic|\(listen)"
        }
    }

    nonisolated static func parseEditorLine(_ line: String) -> SSHPortForward? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let rawKind = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let kind = SSHPortForwardKind(rawValue: rawKind),
              parts.count >= 2 else {
            return nil
        }

        let listen = parseEndpoint(parts[1])
        guard listen.port > 0 else { return nil }
        if kind == .dynamic {
            return SSHPortForward(kind: kind, bindHost: listen.host, bindPort: listen.port)
        }

        guard parts.count >= 3 else { return nil }
        let destination = parseEndpoint(parts[2])
        guard !destination.host.isEmpty, destination.port > 0 else { return nil }
        return SSHPortForward(
            kind: kind,
            bindHost: listen.host,
            bindPort: listen.port,
            destinationHost: destination.host,
            destinationPort: destination.port
        )
    }

    private var browserHost: String {
        let cleanHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty
            || cleanHost == "*"
            || cleanHost == "0.0.0.0"
            || cleanHost == "::" {
            return "localhost"
        }
        if cleanHost.contains(":")
            && !cleanHost.hasPrefix("[")
            && !cleanHost.hasSuffix("]") {
            return "[\(cleanHost)]"
        }
        return cleanHost
    }

    private static func displayEndpoint(host: String, port: Int) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.contains(":")
            && !cleanHost.hasPrefix("[")
            && !cleanHost.hasSuffix("]") {
            return "[\(cleanHost)]:\(port)"
        }
        return "\(cleanHost):\(port)"
    }

    private nonisolated static func parseEndpoint(_ value: String) -> (host: String, port: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", 0) }
        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let remainder = String(trimmed[trimmed.index(after: closing)...])
            guard remainder.hasPrefix(":") else { return ("", 0) }
            return (host, Int(remainder.dropFirst()) ?? 0)
        }
        guard let separator = trimmed.lastIndex(of: ":") else {
            return ("", Int(trimmed) ?? 0)
        }
        let host = String(trimmed[..<separator])
        let port = String(trimmed[trimmed.index(after: separator)...])
        return (host, Int(port) ?? 0)
    }
}

struct SSHPortForwardAccessEntry: Equatable, Identifiable {
    let kind: SSHPortForwardKind
    let urlString: String

    var id: String {
        "\(kind.rawValue)|\(urlString)"
    }

    var canOpenInBrowser: Bool {
        kind == .local
    }

    var summaryLine: String {
        switch kind {
        case .local:
            return L10n.format("ssh.port_forward.access.local", urlString)
        case .dynamic:
            return L10n.format("ssh.port_forward.access.dynamic", urlString)
        case .remote:
            return ""
        }
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
    var isFavorite: Bool
    var lastConnectedAt: Date?
    var connectionOpenCount: Int
    var environment: TerminalEnvironmentKind
    var safetyPolicy: SSHSafetyConfirmationPolicy
    var groupName: String
    var tags: [String]

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
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil,
        connectionOpenCount: Int = 0,
        environment: TerminalEnvironmentKind = .development,
        safetyPolicy: SSHSafetyConfirmationPolicy? = nil,
        groupName: String = "",
        tags: [String] = []
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
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
        self.connectionOpenCount = connectionOpenCount
        self.environment = environment
        self.safetyPolicy = safetyPolicy ?? Self.defaultSafetyPolicy(for: environment)
        self.groupName = groupName
        self.tags = tags
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
        case isFavorite
        case lastConnectedAt
        case connectionOpenCount
        case environment
        case safetyPolicy
        case groupName
        case tags
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
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        connectionOpenCount = try container.decodeIfPresent(Int.self, forKey: .connectionOpenCount) ?? 0
        environment = try container.decodeIfPresent(TerminalEnvironmentKind.self, forKey: .environment) ?? .development
        safetyPolicy = try container.decodeIfPresent(SSHSafetyConfirmationPolicy.self, forKey: .safetyPolicy)
            ?? Self.defaultSafetyPolicy(for: environment)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
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
            isFavorite: isFavorite,
            lastConnectedAt: lastConnectedAt,
            connectionOpenCount: max(connectionOpenCount, 0),
            environment: environment,
            safetyPolicy: safetyPolicy,
            groupName: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags.cleanedTagList()
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

    var groupDisplayName: String {
        let clean = normalized.groupName
        return clean.isEmpty ? L10n.string("ssh.group.ungrouped") : clean
    }

    func matchesSearch(_ query: String, selectedTag: String? = nil) -> Bool {
        let clean = normalized
        if let selectedTag, !clean.tags.contains(where: { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }) {
            return false
        }

        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard !terms.isEmpty else { return true }

        let haystacks = searchTokens.map { $0.lowercased() }
        return terms.allSatisfy { term in
            haystacks.contains(where: { $0.contains(term) })
        }
    }

    var searchTokens: [String] {
        let clean = normalized
        return [
            clean.displayName,
            clean.name,
            clean.host,
            clean.user,
            clean.target,
            clean.groupName,
            clean.environment.name,
            clean.environment.shortName
        ]
            + (clean.isFavorite ? [L10n.string("ssh.group.favorites"), "favorite", "star"] : [])
            + (clean.lastConnectedAt == nil ? [] : [L10n.string("ssh.group.recent"), "recent"])
            + clean.tags
            + clean.jumpHosts.flatMap { [$0.displayName, $0.host, $0.user, $0.name] }
    }

    var recentConnectionSummary: String? {
        let clean = normalized
        guard let lastConnectedAt = clean.lastConnectedAt else { return nil }
        let formattedDate = Self.recentConnectionDateString(lastConnectedAt)
        return L10n.format("ssh.recent.summary", formattedDate, clean.connectionOpenCount)
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

    var healthSummary: SSHProfileHealthSummary {
        SSHProfileHealthSummary(
            preflightIssues: preflightIssues,
            securityWarnings: securityWarningKinds
        )
    }

    var usablePortForwards: [SSHPortForward] {
        normalized.portForwards.map(\.normalized).filter(\.isUsable)
    }

    var portForwardSummaryLines: [String] {
        usablePortForwards.map(\.summaryLine)
    }

    var portForwardSummaryText: String {
        portForwardSummaryLines.joined(separator: "\n")
    }

    var portForwardAccessLines: [String] {
        portForwardAccessEntries.map(\.summaryLine).filter { !$0.isEmpty }
    }

    var portForwardAccessEntries: [SSHPortForwardAccessEntry] {
        var seenAccessURLs: Set<String> = []
        return usablePortForwards.compactMap { forward in
            guard let entry = forward.accessEntry,
                  seenAccessURLs.insert(entry.urlString).inserted else {
                return nil
            }
            return entry
        }
    }

    var portForwardAccessText: String {
        portForwardAccessLines.joined(separator: "\n")
    }

    var portForwardClipboardText: String {
        let summary = portForwardSummaryText
        let access = portForwardAccessText
        guard !summary.isEmpty else { return access }
        guard !access.isEmpty else { return summary }
        return "\(summary)\n\n\(L10n.string("ssh.port_forward.access"))\n\(access)"
    }

    var connectionCapabilityLines: [String] {
        let clean = normalized
        let manualOptions = Set(clean.extraOptions.compactMap(Self.sshOptionName))
        var lines: [String] = []

        if manualOptions.contains("serveraliveinterval") || manualOptions.contains("serveralivecountmax") {
            lines.append(L10n.string("ssh.capability.keep_alive.manual"))
        } else if clean.keepAliveEnabled {
            lines.append(L10n.format(
                "ssh.capability.keep_alive.enabled",
                clean.keepAliveIntervalSeconds,
                clean.keepAliveCountMax
            ))
        } else {
            lines.append(L10n.string("ssh.capability.keep_alive.disabled"))
        }

        if manualOptions.contains("controlmaster")
            || manualOptions.contains("controlpersist")
            || manualOptions.contains("controlpath") {
            lines.append(L10n.string("ssh.capability.reuse.manual"))
        } else if clean.connectionReuseEnabled {
            lines.append(L10n.format(
                "ssh.capability.reuse.enabled",
                clean.connectionReusePersistMinutes
            ))
        } else {
            lines.append(L10n.string("ssh.capability.reuse.disabled"))
        }

        if clean.automaticReconnectEnabled && clean.automaticReconnectAttempts > 0 {
            lines.append(L10n.format(
                "ssh.capability.reconnect.enabled",
                clean.automaticReconnectAttempts,
                clean.automaticReconnectDelaySeconds
            ))
        } else {
            lines.append(L10n.string("ssh.capability.reconnect.disabled"))
        }

        if !clean.usablePortForwards.isEmpty {
            if manualOptions.contains("exitonforwardfailure") {
                lines.append(L10n.string("ssh.capability.forward_failure.manual"))
            } else {
                lines.append(L10n.string("ssh.capability.forward_failure.enabled"))
            }
        }

        return lines
    }

    var connectionCapabilityText: String {
        let lines = connectionCapabilityLines
        guard !lines.isEmpty else { return "" }
        return ([L10n.string("ssh.capability.summary")] + lines).joined(separator: "\n")
    }

    private static func recentConnectionDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private nonisolated static func sshOptionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first?.lowercased()
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

    @discardableResult
    func importProfiles(_ importedProfiles: [SSHConnectionProfile]) -> Int {
        var importedCount = 0
        for profile in importedProfiles {
            let clean = profile.normalized
            guard !clean.host.isEmpty else { continue }
            profiles.removeAll { existing in
                if !clean.name.isEmpty, !existing.name.isEmpty {
                    return existing.name.caseInsensitiveCompare(clean.name) == .orderedSame
                }
                return existing.host.caseInsensitiveCompare(clean.host) == .orderedSame
                    && existing.user.caseInsensitiveCompare(clean.user) == .orderedSame
                    && existing.port == clean.port
            }
            profiles.append(clean)
            importedCount += 1
        }
        guard importedCount > 0 else { return 0 }
        profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persist()
        return importedCount
    }

    @discardableResult
    func importDefaultOpenSSHConfig() throws -> Int {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw SSHConfigImportError.missingDefaultConfig
        }
        return importProfiles(try OpenSSHConfigImporter.profiles(fromFileAt: configURL))
    }

    func delete(_ profile: SSHConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func toggleFavorite(_ profile: SSHConnectionProfile) {
        setFavorite(profile, isFavorite: !profile.normalized.isFavorite)
    }

    func setFavorite(_ profile: SSHConnectionProfile, isFavorite: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var clean = profiles[index].normalized
        clean.isFavorite = isFavorite
        profiles[index] = clean.normalized
        persist()
    }

    @discardableResult
    func recordConnection(_ profile: SSHConnectionProfile, at date: Date = Date()) -> SSHConnectionProfile {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return profile.normalized }
        var clean = profiles[index].normalized
        clean.lastConnectedAt = date
        if clean.connectionOpenCount < Int.max {
            clean.connectionOpenCount += 1
        }
        profiles[index] = clean.normalized
        persist()
        return profiles[index]
    }

    func clearRecentConnection(_ profile: SSHConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var clean = profiles[index].normalized
        clean.lastConnectedAt = nil
        clean.connectionOpenCount = 0
        profiles[index] = clean.normalized
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

struct SSHConfigPreview: Equatable {
    let config: String
    let configURL: URL
    let targetAlias: String
    let hostBlockCount: Int
    let lineCount: Int
    let commands: [SSHConfigPreviewCommand]
}

struct SSHConfigPreviewCommand: Equatable, Identifiable {
    let title: String
    let command: String
    let diagnosticStep: SSHRouteDiagnosticPlanStep

    var id: String {
        "\(title)-\(command)"
    }
}

enum SSHConfigMaterializer {
    static func descriptor(for profile: SSHConnectionProfile) throws -> SSHLaunchDescriptor {
        let clean = profile.normalized
        _ = try ensureConfigDirectory()
        let controlPathDirectory = try ensureControlPathDirectory()
        let configURL = configFileURL(for: clean)
        let aliases = aliases(for: clean)
        let controlPathTemplate = controlPathDirectory.appendingPathComponent("cm-%C").path
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

    static func exportSnippet(for profile: SSHConnectionProfile) -> String {
        renderConfig(profile: profile)
    }

    static func copyableConnectionCommand(for profile: SSHConnectionProfile) throws -> String {
        let descriptor = try descriptor(for: profile)
        return commandLine(executable: descriptor.executable, args: descriptor.args)
    }

    static func previewConnectionCommand(for profile: SSHConnectionProfile) -> String {
        let clean = profile.normalized
        let aliases = aliases(for: clean)
        return commandLine(
            executable: "/usr/bin/ssh",
            args: ["-tt", "-F", configFileURL(for: clean).path, aliases.target]
        )
    }

    static func preview(for profile: SSHConnectionProfile) -> SSHConfigPreview {
        let clean = profile.normalized
        let aliases = aliases(for: clean)
        let configURL = configFileURL(for: clean)
        let controlPathTemplate = controlPathDirectoryURL().appendingPathComponent("cm-%C").path
        let config = renderConfig(profile: clean, aliases: aliases, controlPathTemplate: controlPathTemplate)
        return SSHConfigPreview(
            config: config,
            configURL: configURL,
            targetAlias: aliases.target,
            hostBlockCount: clean.jumpHosts.count + 1,
            lineCount: config.split(whereSeparator: \.isNewline).count,
            commands: previewCommands(for: clean, aliases: aliases, configURL: configURL)
        )
    }

    @discardableResult
    static func writePreviewConfig(for profile: SSHConnectionProfile) throws -> SSHConfigPreview {
        let preview = preview(for: profile)
        _ = try ensureConfigDirectory()
        _ = try ensureControlPathDirectory()
        try Data(preview.config.utf8).write(to: preview.configURL, options: .atomic)
        return preview
    }

    static func configFileURL(for profile: SSHConnectionProfile) -> URL {
        configDirectoryURL().appendingPathComponent("\(profile.normalized.id.uuidString).conf")
    }

    static func targetAlias(for profile: SSHConnectionProfile) -> String {
        aliases(for: profile.normalized).target
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

    private struct PreviewRouteStep {
        let kind: SSHRouteDiagnosticStepKind
        let host: String
        let port: Int
        let alias: String
    }

    private static func previewCommands(
        for profile: SSHConnectionProfile,
        aliases: HostAliases,
        configURL: URL
    ) -> [SSHConfigPreviewCommand] {
        guard let firstStep = firstPreviewRouteStep(for: profile) else { return [] }
        let configPath = shellArgument(configURL.path)
        let targetAlias = shellArgument(aliases.target)
        return [
            previewCommand(
                kind: .dnsLookup,
                title: L10n.format("ssh.route_probe.dns", firstStep.host),
                command: "dscacheutil -q host -a name \(shellArgument(firstStep.host)) || nslookup \(shellArgument(firstStep.host))",
                routeStepKind: firstStep.kind,
                host: firstStep.host,
                port: nil,
                alias: firstStep.alias
            ),
            previewCommand(
                kind: .tcpPort,
                title: L10n.format("ssh.route_probe.port", firstStep.host, firstStep.port),
                command: "nc -vz -w 5 \(shellArgument(firstStep.host)) \(firstStep.port)",
                routeStepKind: firstStep.kind,
                host: firstStep.host,
                port: firstStep.port,
                alias: firstStep.alias
            ),
            previewCommand(
                kind: .generatedConfig,
                title: L10n.string("ssh.route_probe.config"),
                command: "ssh -G -F \(configPath) \(targetAlias)",
                routeStepKind: .target,
                host: profile.host,
                port: profile.port,
                alias: aliases.target
            ),
            previewCommand(
                kind: .verboseRoute,
                title: L10n.format("ssh.route_probe.verbose_target", profile.displayName),
                command: "ssh -vvv -F \(configPath) \(targetAlias) true",
                routeStepKind: .target,
                host: profile.host,
                port: profile.port,
                alias: aliases.target
            )
        ]
    }

    private static func firstPreviewRouteStep(for profile: SSHConnectionProfile) -> PreviewRouteStep? {
        let aliases = aliases(for: profile)
        if let jump = profile.jumpHosts.first {
            return PreviewRouteStep(kind: .jump(index: 1), host: jump.host, port: jump.port, alias: aliases.jumps[0])
        }
        guard !profile.host.isEmpty else { return nil }
        return PreviewRouteStep(kind: .target, host: profile.host, port: profile.port, alias: aliases.target)
    }

    private static func previewCommand(
        kind: SSHRouteDiagnosticProbeKind,
        title: String,
        command: String,
        routeStepKind: SSHRouteDiagnosticStepKind?,
        host: String?,
        port: Int?,
        alias: String?
    ) -> SSHConfigPreviewCommand {
        let diagnosticStep = SSHRouteDiagnosticPlanStep(
            kind: kind,
            title: title,
            command: command,
            routeStepKind: routeStepKind,
            host: host,
            port: port,
            alias: alias,
            includeInFailureGuide: true
        )
        return SSHConfigPreviewCommand(
            title: title,
            command: command,
            diagnosticStep: diagnosticStep
        )
    }

    private static func renderConfig(
        profile: SSHConnectionProfile,
        aliases: HostAliases,
        controlPathTemplate: String
    ) -> String {
        let extraOptions = effectiveExtraOptions(for: profile)
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
            extraOptions: connectionReuseOptions(
                for: profile,
                extraOptions: extraOptions,
                controlPathTemplate: controlPathTemplate
            )
                + keepAliveOptions(for: profile, extraOptions: extraOptions)
                + portForwardOptions(for: profile, extraOptions: extraOptions)
                + extraOptions
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
        extraOptions: [String],
        controlPathTemplate: String
    ) -> [String] {
        guard profile.connectionReuseEnabled else { return [] }

        let manualOptions = Set(extraOptions.compactMap { optionName($0) })
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

    private static func keepAliveOptions(for profile: SSHConnectionProfile, extraOptions: [String]) -> [String] {
        guard profile.keepAliveEnabled else { return [] }

        let manualOptions = Set(extraOptions.compactMap { optionName($0) })
        var options: [String] = []
        if !manualOptions.contains("serveraliveinterval") {
            options.append("ServerAliveInterval \(profile.keepAliveIntervalSeconds)")
        }
        if !manualOptions.contains("serveralivecountmax") {
            options.append("ServerAliveCountMax \(profile.keepAliveCountMax)")
        }
        return options
    }

    private static func portForwardOptions(for profile: SSHConnectionProfile, extraOptions: [String]) -> [String] {
        let forwards = profile.portForwards.map(\.normalized).filter(\.isUsable)
        guard !forwards.isEmpty else { return [] }

        let manualOptions = Set(extraOptions.compactMap { optionName($0) })
        var options: [String] = []
        if !manualOptions.contains("exitonforwardfailure") {
            options.append("ExitOnForwardFailure yes")
        }

        for forward in forwards {
            let listen = listenSpec(host: forward.bindHost, port: forward.bindPort)
            switch forward.kind {
            case .local:
                let destination = endpointSpec(host: forward.destinationHost, port: forward.destinationPort)
                options.append("LocalForward \(listen) \(destination)")
            case .remote:
                let destination = endpointSpec(host: forward.destinationHost, port: forward.destinationPort)
                options.append("RemoteForward \(listen) \(destination)")
            case .dynamic:
                options.append("DynamicForward \(listen)")
            }
        }
        return options
    }

    private static func effectiveExtraOptions(for profile: SSHConnectionProfile) -> [String] {
        profile.extraOptions.filter { !isLegacyGeneratedControlPathOption($0) }
    }

    private static func isLegacyGeneratedControlPathOption(_ line: String) -> Bool {
        guard optionName(line) == "controlpath",
              let value = optionValue(line) else {
            return false
        }
        let controlPath = expandTilde(unquoteOptionValue(value))
        let legacyPrefix = configDirectoryURL().appendingPathComponent("cm-").path
        return controlPath.hasPrefix(legacyPrefix)
    }

    private static func listenSpec(host: String, port: Int) -> String {
        host.isEmpty ? "\(port)" : endpointSpec(host: host, port: port)
    }

    private static func endpointSpec(host: String, port: Int) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.contains(":")
            && !cleanHost.hasPrefix("[")
            && !cleanHost.hasSuffix("]") {
            return "[\(cleanHost)]:\(port)"
        }
        return "\(cleanHost):\(port)"
    }

    private static func commandLine(executable: String, args: [String]) -> String {
        ([executable] + args).map(shellCommandWord).joined(separator: " ")
    }

    private static func shellCommandWord(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy(isSafeShellCommandScalar) else {
            return shellArgument(value)
        }
        return value
    }

    private static func isSafeShellCommandScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 45, 46, 47, 58, 61, 64, 95, 43, 44, 37, 126:
            return true
        default:
            return false
        }
    }

    private static func optionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first?.lowercased()
    }

    private static func optionValue(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        var remainder = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.first == "=" {
            remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let value = String(remainder)
        return value.isEmpty ? nil : value
    }

    private static func ensureConfigDirectory() throws -> URL {
        let directory = configDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func ensureControlPathDirectory() throws -> URL {
        let directory = controlPathDirectoryURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            throw NSError(
                domain: "MuseTerm.SSHControlPath",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "SSH control socket directory is not owned by the current user: \(directory.path)"
                ]
            )
        }
        return directory
    }

    private static func configDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
    }

    private static func controlPathDirectoryURL() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mtssh-\(getuid())", isDirectory: true)
    }

    private static func expandTilde(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func unquoteOptionValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private nonisolated static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    func expandingTildePath() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
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

    func cleanedTagList() -> [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        for rawTag in self {
            let tag = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !tag.isEmpty else { continue }
            let key = tag.lowercased()
            guard seen.insert(key).inserted else { continue }
            tags.append(tag)
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
