import Foundation

enum SSHRouteDiagnosticResultStatus: String, Equatable {
    case passed
    case failed
    case needsAttention
    case unknown

    var title: String {
        L10n.string("ssh.route_result.status.\(rawValue)")
    }
}

struct SSHRouteDiagnosticStepResult: Equatable {
    let status: SSHRouteDiagnosticResultStatus
    let summary: String
    let evidence: String?
}

struct SSHRouteDiagnosticResultSummary: Equatable {
    let totalSteps: Int
    let parsedSteps: Int
    let passed: Int
    let failed: Int
    let needsAttention: Int
    let unknown: Int

    init(totalSteps: Int, results: [Int: SSHRouteDiagnosticStepResult]) {
        self.totalSteps = totalSteps
        let scopedResults = (0..<max(totalSteps, 0)).compactMap { results[$0] }
        self.parsedSteps = scopedResults.count
        self.passed = scopedResults.filter { $0.status == .passed }.count
        self.failed = scopedResults.filter { $0.status == .failed }.count
        self.needsAttention = scopedResults.filter { $0.status == .needsAttention }.count
        self.unknown = scopedResults.filter { $0.status == .unknown }.count
    }

    var hasResults: Bool {
        parsedSteps > 0
    }

    var remainingSteps: Int {
        max(totalSteps - parsedSteps, 0)
    }

    var leadingStatus: SSHRouteDiagnosticResultStatus? {
        if failed > 0 {
            return .failed
        }
        if needsAttention > 0 {
            return .needsAttention
        }
        if unknown > 0 {
            return .unknown
        }
        if passed > 0 {
            return .passed
        }
        return nil
    }
}

struct SSHRouteDiagnosticReport: Equatable {
    struct Step: Equatable {
        let index: Int
        let title: String
        let command: String
        let result: SSHRouteDiagnosticStepResult
    }

    let profileName: String
    let routeSummary: String
    let generatedAtText: String
    let resultSummary: SSHRouteDiagnosticResultSummary
    let steps: [Step]

    init(
        profileName: String,
        routeSummary: String,
        planSteps: [SSHRouteDiagnosticPlanStep],
        results: [Int: SSHRouteDiagnosticStepResult],
        generatedAtText: String = Self.defaultGeneratedAtText()
    ) {
        self.profileName = profileName
        self.routeSummary = routeSummary
        self.generatedAtText = generatedAtText
        self.resultSummary = SSHRouteDiagnosticResultSummary(totalSteps: planSteps.count, results: results)
        self.steps = planSteps.enumerated().compactMap { index, step in
            guard let result = results[index] else { return nil }
            return Step(index: index + 1, title: step.title, command: step.command, result: result)
        }
    }

    var hasResults: Bool {
        !steps.isEmpty
    }

    var markdown: String {
        var lines: [String] = [
            "# \(L10n.string("ssh.diagnostic_report.title"))",
            "",
            "- **\(L10n.string("ssh.diagnostic_report.profile")):** \(profileName)",
            "- **\(L10n.string("ssh.diagnostic_report.route")):** \(routeSummary)",
            "- **\(L10n.string("ssh.diagnostic_report.generated_at")):** \(generatedAtText)",
            "- **\(L10n.string("ssh.diagnostic_report.summary")):** \(summaryText)",
            "",
            "## \(L10n.string("ssh.diagnostic_report.checks"))"
        ]

        for step in steps {
            lines.append(contentsOf: [
                "",
                "### \(step.index). \(step.title)",
                "- **\(L10n.string("ssh.diagnostic_report.status")):** \(step.result.status.title)",
                "- **\(L10n.string("ssh.diagnostic_report.result")):** \(step.result.summary)"
            ])
            if let evidence = step.result.evidence, !evidence.isEmpty {
                lines.append("- **\(L10n.string("ssh.diagnostic_report.evidence")):** \(evidence)")
            }
            lines.append(contentsOf: [
                "- **\(L10n.string("ssh.diagnostic_report.command")):**",
                commandFenceOpen(for: step.command),
                step.command,
                commandFenceClose(for: step.command)
            ])
        }

        return lines.joined(separator: "\n")
    }

    private var summaryText: String {
        L10n.format(
            "ssh.diagnostic_plan.result_summary",
            resultSummary.parsedSteps,
            resultSummary.totalSteps,
            resultSummary.passed,
            resultSummary.failed,
            resultSummary.needsAttention,
            resultSummary.unknown
        )
    }

    private func commandFenceOpen(for command: String) -> String {
        command.contains("```") ? "````shell" : "```shell"
    }

    private func commandFenceClose(for command: String) -> String {
        command.contains("```") ? "````" : "```"
    }

    private static func defaultGeneratedAtText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

enum SSHRouteDiagnosticStepResultInterpreter {
    private struct Match {
        let summaryKey: String
        let evidence: String?
    }

    static func interpret(
        step: SSHRouteDiagnosticPlanStep,
        exitCode: Int32?,
        output: String
    ) -> SSHRouteDiagnosticStepResult {
        let lines = meaningfulLines(in: output)
        let lowercased = output.lowercased()

        switch step.kind {
        case .dnsLookup:
            if let match = firstMatch(
                in: lines,
                needles: ["no such host", "not found", "can't find", "nxdomain", "nodename nor servname", "servfail"],
                summaryKey: "ssh.route_result.dns.failed"
            ) {
                return result(.failed, match)
            }
            if allowsSuccess(exitCode: exitCode),
               containsAny(lowercased, ["name:", "has address", "canonical name", "address:"]) {
                return SSHRouteDiagnosticStepResult(
                    status: .passed,
                    summary: L10n.string("ssh.route_result.dns.passed"),
                    evidence: firstLine(in: lines, matching: ["name:", "has address", "canonical name", "address:"])
                )
            }
            return fallback(exitCode: exitCode, lines: lines, failedKey: "ssh.route_result.dns.failed")

        case .tcpPort:
            if let match = firstMatch(
                in: lines,
                needles: ["succeeded", "open"],
                summaryKey: "ssh.route_result.tcp.passed"
            ), exitCode == 0 || lowercased.contains("succeeded") {
                return result(.passed, match)
            }
            if let match = firstMatch(
                in: lines,
                needles: ["connection refused"],
                summaryKey: "ssh.route_result.tcp.refused"
            ) {
                return result(.failed, match)
            }
            if let match = firstMatch(
                in: lines,
                needles: ["timed out", "timeout", "no route to host", "network is unreachable", "host is down"],
                summaryKey: "ssh.route_result.tcp.unreachable"
            ) {
                return result(.failed, match)
            }
            return fallback(exitCode: exitCode, lines: lines, failedKey: "ssh.route_result.tcp.failed")

        case .generatedConfig:
            if let match = firstMatch(
                in: lines,
                needles: ["bad configuration option", "terminating", "parse error", "configuration file"],
                summaryKey: "ssh.route_result.config.failed"
            ) {
                return result(.failed, match)
            }
            if allowsSuccess(exitCode: exitCode),
               containsAny(lowercased, ["hostname ", "user ", "port "]) {
                return SSHRouteDiagnosticStepResult(
                    status: .passed,
                    summary: L10n.string("ssh.route_result.config.passed"),
                    evidence: firstLine(in: lines, matching: ["hostname ", "user ", "port "])
                )
            }
            return fallback(exitCode: exitCode, lines: lines, failedKey: "ssh.route_result.config.failed")

        case .verboseRoute:
            if exitCode == 0 || lowercased.contains("debug1: exit status 0") {
                return SSHRouteDiagnosticStepResult(
                    status: .passed,
                    summary: L10n.string("ssh.route_result.verbose.passed"),
                    evidence: firstLineByNeedlePriority(
                        in: lines,
                        matching: ["debug1: exit status 0", "authenticated to", "entering interactive session"]
                    )
                )
            }
            if let issue = SSHConnectionIssueClassifier.classify(output) {
                return SSHRouteDiagnosticStepResult(
                    status: .failed,
                    summary: L10n.format("ssh.route_result.verbose.failed_issue", issue.title),
                    evidence: evidenceLine(in: lines, for: issue)
                )
            }
            return fallback(exitCode: exitCode, lines: lines, failedKey: "ssh.route_result.verbose.failed")
        }
    }

    private static func fallback(
        exitCode: Int32?,
        lines: [String],
        failedKey: String
    ) -> SSHRouteDiagnosticStepResult {
        if let exitCode {
            if exitCode == 0 {
                return SSHRouteDiagnosticStepResult(
                    status: .needsAttention,
                    summary: L10n.string("ssh.route_result.passed_without_signal"),
                    evidence: lines.first
                )
            }
            return SSHRouteDiagnosticStepResult(
                status: .failed,
                summary: L10n.string(failedKey),
                evidence: lines.first
            )
        }
        return SSHRouteDiagnosticStepResult(
            status: .unknown,
            summary: L10n.string("ssh.route_result.unknown"),
            evidence: lines.first
        )
    }

    private static func result(_ status: SSHRouteDiagnosticResultStatus, _ match: Match) -> SSHRouteDiagnosticStepResult {
        SSHRouteDiagnosticStepResult(
            status: status,
            summary: L10n.string(match.summaryKey),
            evidence: match.evidence
        )
    }

    private static func allowsSuccess(exitCode: Int32?) -> Bool {
        guard let exitCode else { return true }
        return exitCode == 0
    }

    private static func meaningfulLines(in output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func firstMatch(in lines: [String], needles: [String], summaryKey: String) -> Match? {
        guard let evidence = firstLine(in: lines, matching: needles) else { return nil }
        return Match(summaryKey: summaryKey, evidence: evidence)
    }

    private static func firstLine(in lines: [String], matching needles: [String]) -> String? {
        lines.first { line in
            containsAny(line.lowercased(), needles)
        }
    }

    private static func firstLineByNeedlePriority(in lines: [String], matching needles: [String]) -> String? {
        needles.lazy.compactMap { needle in
            lines.first { line in
                line.lowercased().contains(needle)
            }
        }.first
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func evidenceLine(in lines: [String], for issue: SSHConnectionIssueKind) -> String? {
        let needles: [String]
        switch issue {
        case .permissionDenied:
            needles = ["permission denied"]
        case .hostKeyVerificationFailed:
            needles = ["host key verification failed", "remote host identification has changed"]
        case .connectionTimedOut:
            needles = ["connection timed out", "operation timed out"]
        case .connectionRefused:
            needles = ["connection refused"]
        case .tooManyAuthenticationFailures:
            needles = ["too many authentication failures"]
        case .portForwardFailure:
            needles = ["cannot listen to port", "port forwarding failed", "channel_setup_fwd_listener", "administratively prohibited"]
        }
        return firstLine(in: lines, matching: needles) ?? lines.first
    }
}
