import Darwin
import Foundation

enum TerminalExecutionTargetKind: String, Codable, Hashable {
    case local
    case ssh
}

enum TerminalExecutionContextConfidence: String, Codable, Hashable {
    case inferred
    case observed
}

struct TerminalShellReportedContext: Equatable {
    var workingDirectory: String?
    var user: String?
    var uid: Int?
    var host: String?
    var shell: String?

    var isEmpty: Bool {
        workingDirectory == nil && user == nil && uid == nil && host == nil && shell == nil
    }
}

struct TerminalExecutionContext: Codable, Equatable, Hashable {
    var targetKind: TerminalExecutionTargetKind
    var targetID: UUID?
    var targetName: String
    var targetFingerprint: String
    var workingDirectory: String?
    var user: String?
    var uid: Int?
    var host: String?
    var port: Int?
    var shell: String?
    var confidence: TerminalExecutionContextConfidence
    var capturedAt: Date

    var learningKey: String {
        [
            targetKind.rawValue,
            targetID?.uuidString ?? targetFingerprint,
            normalizedDirectory ?? "",
            normalizedUser ?? "",
            normalizedShell ?? ""
        ].joined(separator: "\u{1F}")
    }

    var normalizedDirectory: String? {
        Self.nonEmptyTrimmed(workingDirectory)
    }

    var normalizedUser: String? {
        Self.nonEmptyTrimmed(user)
    }

    var normalizedShell: String? {
        guard let shell = Self.nonEmptyTrimmed(shell) else { return nil }
        return URL(fileURLWithPath: shell).lastPathComponent.lowercased()
    }

    var displayTarget: String {
        let cleaned = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        if let host = Self.nonEmptyTrimmed(host) { return host }
        return targetKind == .local
            ? L10n.string("execution_context.local")
            : L10n.string("execution_context.ssh")
    }

    var displaySummary: String {
        var parts = [
            targetKind == .local
                ? L10n.string("execution_context.local")
                : L10n.string("execution_context.ssh"),
            displayTarget
        ]
        if let directory = normalizedDirectory {
            parts.append(directory)
        }
        if let user = normalizedUser {
            parts.append(L10n.format("execution_context.user", user))
        }
        return parts.joined(separator: " · ")
    }

    func matchesTarget(of launchConfiguration: TerminalLaunchConfiguration) -> Bool {
        switch (targetKind, launchConfiguration) {
        case (.local, .localShell(_, let profile)):
            guard let targetID else { return true }
            return profile?.id == targetID
        case (.ssh, .ssh(let profile)):
            guard let targetID else {
                return Self.sshFingerprint(profile.normalized) == targetFingerprint
            }
            return profile.id == targetID
                && Self.sshFingerprint(profile.normalized) == targetFingerprint
        default:
            return false
        }
    }

    func matchesReportedContext(_ report: TerminalShellReportedContext) -> Bool {
        if let expectedUser = normalizedUser {
            guard let reportedUser = Self.nonEmptyTrimmed(report.user),
                  expectedUser == reportedUser else { return false }
        }
        if let expectedDirectory = normalizedDirectory {
            guard let reportedDirectory = Self.nonEmptyTrimmed(report.workingDirectory),
                  Self.standardizedPath(expectedDirectory) == Self.standardizedPath(reportedDirectory) else {
                return false
            }
        }
        return true
    }

    static func inferred(
        launchConfiguration: TerminalLaunchConfiguration,
        currentDirectory: String?,
        shellName: String?,
        now: Date = Date()
    ) -> TerminalExecutionContext {
        context(
            launchConfiguration: launchConfiguration,
            currentDirectory: currentDirectory,
            shellName: shellName,
            report: nil,
            now: now
        )
    }

    static func observed(
        launchConfiguration: TerminalLaunchConfiguration,
        currentDirectory: String?,
        shellName: String?,
        report: TerminalShellReportedContext,
        now: Date = Date()
    ) -> TerminalExecutionContext {
        context(
            launchConfiguration: launchConfiguration,
            currentDirectory: currentDirectory,
            shellName: shellName,
            report: report,
            now: now
        )
    }

    private static func context(
        launchConfiguration: TerminalLaunchConfiguration,
        currentDirectory: String?,
        shellName: String?,
        report: TerminalShellReportedContext?,
        now: Date
    ) -> TerminalExecutionContext {
        switch launchConfiguration {
        case .localShell(_, let profile):
            let localHost = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let localUser = NSUserName()
            return TerminalExecutionContext(
                targetKind: .local,
                targetID: profile?.id,
                targetName: profile?.displayName ?? L10n.string("profile.default.name"),
                targetFingerprint: profile.map { "local:\($0.id.uuidString)" } ?? "local:system",
                workingDirectory: nonEmptyTrimmed(report?.workingDirectory) ?? nonEmptyTrimmed(currentDirectory),
                user: nonEmptyTrimmed(report?.user) ?? localUser,
                uid: report?.uid ?? Int(getuid()),
                host: nonEmptyTrimmed(report?.host) ?? localHost,
                port: nil,
                shell: nonEmptyTrimmed(report?.shell) ?? nonEmptyTrimmed(shellName),
                confidence: report?.isEmpty == false ? .observed : .inferred,
                capturedAt: now
            )
        case .ssh(let profile):
            let clean = profile.normalized
            return TerminalExecutionContext(
                targetKind: .ssh,
                targetID: clean.id,
                targetName: clean.displayName,
                targetFingerprint: sshFingerprint(clean),
                workingDirectory: nonEmptyTrimmed(report?.workingDirectory) ?? nonEmptyTrimmed(currentDirectory),
                user: nonEmptyTrimmed(report?.user) ?? nonEmptyTrimmed(clean.user),
                uid: report?.uid,
                host: nonEmptyTrimmed(report?.host) ?? nonEmptyTrimmed(clean.host),
                port: clean.port,
                shell: nonEmptyTrimmed(report?.shell) ?? nonEmptyTrimmed(shellName),
                confidence: report?.isEmpty == false ? .observed : .inferred,
                capturedAt: now
            )
        }
    }

    static func sshFingerprint(_ profile: SSHConnectionProfile) -> String {
        let clean = profile.normalized
        return [clean.id.uuidString, clean.user, clean.host, String(clean.port)].joined(separator: "|")
    }

    private static func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }
}
