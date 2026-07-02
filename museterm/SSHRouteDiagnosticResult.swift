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
            if exitCode == 0,
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
            if exitCode == 0,
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
