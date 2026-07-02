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

enum SSHRouteDiagnosticRecommendationKind: String, Equatable {
    case allPassed
    case continueChecks
    case dnsFailure
    case tcpFailure
    case configFailure
    case verboseFailure
    case needsAttention
    case unknown
}

struct SSHRouteDiagnosticRecommendation: Equatable {
    let kind: SSHRouteDiagnosticRecommendationKind
    let status: SSHRouteDiagnosticResultStatus
    let relatedStepIndex: Int?
    let title: String
    let summary: String
    let action: String
}

enum SSHRouteDiagnosticAdvisor {
    static func recommendation(
        planSteps: [SSHRouteDiagnosticPlanStep],
        results: [Int: SSHRouteDiagnosticStepResult]
    ) -> SSHRouteDiagnosticRecommendation? {
        let summary = SSHRouteDiagnosticResultSummary(totalSteps: planSteps.count, results: results)
        guard summary.hasResults else { return nil }

        if let failed = firstResult(with: .failed, planSteps: planSteps, results: results) {
            return recommendation(forFailedStep: failed.step, index: failed.index)
        }
        if let attention = firstResult(with: .needsAttention, planSteps: planSteps, results: results) {
            return recommendation(kind: .needsAttention, status: .needsAttention, step: attention.step, index: attention.index)
        }
        if let unknown = firstResult(with: .unknown, planSteps: planSteps, results: results) {
            return recommendation(kind: .unknown, status: .unknown, step: unknown.step, index: unknown.index)
        }
        if summary.parsedSteps == planSteps.count {
            return recommendation(kind: .allPassed, status: .passed, step: nil, index: nil)
        }
        return recommendation(kind: .continueChecks, status: .passed, step: nil, index: nil)
    }

    private static func firstResult(
        with status: SSHRouteDiagnosticResultStatus,
        planSteps: [SSHRouteDiagnosticPlanStep],
        results: [Int: SSHRouteDiagnosticStepResult]
    ) -> (index: Int, step: SSHRouteDiagnosticPlanStep)? {
        for index in planSteps.indices where results[index]?.status == status {
            return (index, planSteps[index])
        }
        return nil
    }

    private static func recommendation(
        forFailedStep step: SSHRouteDiagnosticPlanStep,
        index: Int
    ) -> SSHRouteDiagnosticRecommendation {
        let kind: SSHRouteDiagnosticRecommendationKind
        switch step.kind {
        case .dnsLookup:
            kind = .dnsFailure
        case .tcpPort:
            kind = .tcpFailure
        case .generatedConfig:
            kind = .configFailure
        case .verboseRoute:
            kind = .verboseFailure
        }
        return recommendation(kind: kind, status: .failed, step: step, index: index)
    }

    private static func recommendation(
        kind: SSHRouteDiagnosticRecommendationKind,
        status: SSHRouteDiagnosticResultStatus,
        step: SSHRouteDiagnosticPlanStep?,
        index: Int?
    ) -> SSHRouteDiagnosticRecommendation {
        let stepTitle = step?.title ?? L10n.string("ssh.diagnostic_recommendation.step.none")
        return SSHRouteDiagnosticRecommendation(
            kind: kind,
            status: status,
            relatedStepIndex: index.map { $0 + 1 },
            title: L10n.string("ssh.diagnostic_recommendation.\(kind.rawValue).title"),
            summary: L10n.format("ssh.diagnostic_recommendation.\(kind.rawValue).summary", stepTitle),
            action: L10n.string("ssh.diagnostic_recommendation.\(kind.rawValue).action")
        )
    }
}

struct SSHRouteDiagnosticReport: Equatable {
    struct Step: Equatable {
        let index: Int
        let title: String
        let command: String
        let diagnosticStep: SSHRouteDiagnosticPlanStep
        let result: SSHRouteDiagnosticStepResult
    }

    let profileName: String
    let routeSummary: String
    let generatedAtText: String
    let redactsSensitiveData: Bool
    let resultSummary: SSHRouteDiagnosticResultSummary
    let steps: [Step]
    private let planSteps: [SSHRouteDiagnosticPlanStep]
    private let results: [Int: SSHRouteDiagnosticStepResult]

    init(
        profileName: String,
        routeSummary: String,
        planSteps: [SSHRouteDiagnosticPlanStep],
        results: [Int: SSHRouteDiagnosticStepResult],
        generatedAtText: String = Self.defaultGeneratedAtText(),
        redactsSensitiveData: Bool = true
    ) {
        self.profileName = profileName
        self.routeSummary = routeSummary
        self.generatedAtText = generatedAtText
        self.redactsSensitiveData = redactsSensitiveData
        self.planSteps = planSteps
        self.results = results
        self.resultSummary = SSHRouteDiagnosticResultSummary(totalSteps: planSteps.count, results: results)
        self.steps = planSteps.enumerated().compactMap { index, step in
            guard let result = results[index] else { return nil }
            return Step(
                index: index + 1,
                title: step.title,
                command: step.command,
                diagnosticStep: step,
                result: result
            )
        }
    }

    var hasResults: Bool {
        !steps.isEmpty
    }

    var markdown: String {
        var lines: [String] = [
            "# \(L10n.string("ssh.diagnostic_report.title"))",
            "",
            "- **\(L10n.string("ssh.diagnostic_report.profile")):** \(reportText(profileName))",
            "- **\(L10n.string("ssh.diagnostic_report.route")):** \(reportText(routeSummary))",
            "- **\(L10n.string("ssh.diagnostic_report.generated_at")):** \(generatedAtText)",
            "- **\(L10n.string("ssh.diagnostic_report.summary")):** \(summaryText)",
            "- **\(L10n.string("runbook.redaction")):** \(redactionText)",
            "- **\(L10n.string("ssh.diagnostic_report.sensitive_content")):** \(sensitiveContentText)",
            "",
            "## \(L10n.string("ssh.diagnostic_report.recommendation"))"
        ]

        lines.append(contentsOf: recommendationLines)
        lines.append(contentsOf: [
            "",
            "## \(L10n.string("ssh.diagnostic_report.checks"))"
        ])

        for step in steps {
            let command = reportText(step.command)
            lines.append(contentsOf: [
                "",
                "### \(step.index). \(reportText(step.title))",
                "- **\(L10n.string("ssh.diagnostic_report.status")):** \(step.result.status.title)",
                "- **\(L10n.string("ssh.diagnostic_report.result")):** \(reportText(step.result.summary))"
            ])
            if let evidence = step.result.evidence, !evidence.isEmpty {
                lines.append("- **\(L10n.string("ssh.diagnostic_report.evidence")):** \(reportText(evidence))")
            }
            lines.append(contentsOf: [
                "- **\(L10n.string("ssh.diagnostic_report.command")):**",
                commandFenceOpen(for: command),
                command,
                commandFenceClose(for: command)
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

    private var redactionText: String {
        L10n.string(redactsSensitiveData ? "runbook.redaction_on" : "runbook.redaction_off")
    }

    private var recommendationLines: [String] {
        guard let recommendation = SSHRouteDiagnosticAdvisor.recommendation(
            planSteps: planSteps,
            results: results
        ) else {
            return ["- \(L10n.string("ssh.diagnostic_report.recommendation.none"))"]
        }

        var lines = [
            "- **\(L10n.string("ssh.diagnostic_report.recommendation.title")):** \(reportText(recommendation.title))",
            "- **\(L10n.string("ssh.diagnostic_report.recommendation.status")):** \(recommendation.status.title)"
        ]
        if let relatedStepIndex = recommendation.relatedStepIndex {
            lines.append(
                "- **\(L10n.string("ssh.diagnostic_report.recommendation.step")):** \(recommendationStepText(for: relatedStepIndex))"
            )
            if let command = recommendationCommandText(for: relatedStepIndex), !command.isEmpty {
                lines.append(contentsOf: [
                    "- **\(L10n.string("ssh.diagnostic_report.recommendation.command")):**",
                    commandFenceOpen(for: command),
                    command,
                    commandFenceClose(for: command)
                ])
            }
            if let evidence = recommendationEvidenceText(for: relatedStepIndex), !evidence.isEmpty {
                lines.append("- **\(L10n.string("ssh.diagnostic_report.recommendation.evidence")):** \(evidence)")
            }
        }
        lines.append(contentsOf: [
            "- **\(L10n.string("ssh.diagnostic_report.recommendation.summary")):** \(reportText(recommendation.summary))",
            "- **\(L10n.string("ssh.diagnostic_report.recommendation.action")):** \(reportText(recommendation.action))"
        ])
        return lines
    }

    private func recommendationStepText(for oneBasedIndex: Int) -> String {
        let title = planSteps.indices.contains(oneBasedIndex - 1)
            ? planSteps[oneBasedIndex - 1].title
            : L10n.string("ssh.diagnostic_recommendation.step.none")
        return reportText(L10n.format("ssh.diagnostic_report.recommendation.step_value", oneBasedIndex, title))
    }

    private func recommendationCommandText(for oneBasedIndex: Int) -> String? {
        guard planSteps.indices.contains(oneBasedIndex - 1) else { return nil }
        return reportText(planSteps[oneBasedIndex - 1].command)
    }

    private func recommendationEvidenceText(for oneBasedIndex: Int) -> String? {
        guard let evidence = results[oneBasedIndex - 1]?.evidence else { return nil }
        return reportText(evidence)
    }

    private var sensitiveContentText: String {
        let key: String
        switch (containsSensitiveContent, redactsSensitiveData) {
        case (true, true):
            key = "ssh.diagnostic_report.sensitive_content_redacted"
        case (true, false):
            key = "ssh.diagnostic_report.sensitive_content_detected_unredacted"
        case (false, _):
            key = "ssh.diagnostic_report.sensitive_content_not_detected"
        }
        return L10n.string(key)
    }

    private var containsSensitiveContent: Bool {
        rawReportTexts.contains { RunbookSensitiveRedactor.containsSensitiveData($0) }
    }

    private var rawReportTexts: [String] {
        [profileName, routeSummary] + steps.flatMap { step in
            [
                step.title,
                step.command,
                step.result.summary,
                step.result.evidence ?? ""
            ]
        }
    }

    private func reportText(_ text: String) -> String {
        redactsSensitiveData ? RunbookSensitiveRedactor.redact(text) : text
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
