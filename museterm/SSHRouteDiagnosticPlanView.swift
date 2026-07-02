import AppKit
import SwiftUI

struct SSHRouteDiagnosticPlanSheet: View {
    let profile: SSHConnectionProfile
    @ObservedObject var workspace: TerminalWorkspace
    let skin: TerminalVisualSkin
    let onClose: () -> Void
    @State private var message = ""
    @State private var parsedResults: [Int: SSHRouteDiagnosticStepResult] = [:]

    private var plan: SSHRouteDiagnosticPlan? {
        SSHRouteProbeGuideBuilder.plan(for: profile, issue: .connectionTimedOut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let plan {
                routeSummary(plan.routeSummary)
                resultSummary(totalSteps: plan.steps.count)
                stepList(plan.steps)
                footer(plan.steps)
            } else {
                emptyState
            }

            HStack {
                if !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.string("action.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 680, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: profile.jumpHosts.isEmpty ? "network" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(skin.accent)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("ssh.diagnostic_plan.title"))
                    .font(.headline)
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("ssh.diagnostic_plan.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            EnvironmentBadge(environment: profile.environment)
        }
    }

    private func routeSummary(_ summary: String) -> some View {
        Label {
            Text(summary)
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func resultSummary(totalSteps: Int) -> some View {
        let summary = SSHRouteDiagnosticResultSummary(totalSteps: totalSteps, results: parsedResults)
        if summary.hasResults {
            Label {
                Text(
                    L10n.format(
                        "ssh.diagnostic_plan.result_summary",
                        summary.parsedSteps,
                        summary.totalSteps,
                        summary.passed,
                        summary.failed,
                        summary.needsAttention,
                        summary.unknown
                    )
                )
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: resultSummaryIcon(summary.leadingStatus))
            }
            .foregroundStyle(resultSummaryColor(summary.leadingStatus))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(resultSummaryColor(summary.leadingStatus).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func stepList(_ steps: [SSHRouteDiagnosticPlanStep]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    SSHRouteDiagnosticStepRow(
                        index: index + 1,
                        step: step,
                        skin: skin,
                        result: parsedResults[index],
                        canStage: hasLocalSelectedTab,
                        stageHelp: stageHelp,
                        copyAction: { copy(step.command, messageKey: "ssh.diagnostic_plan.copied_step") },
                        parseClipboardAction: { parseClipboardResult(for: step, at: index) },
                        stageAction: { stage(step.command) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func footer(_ steps: [SSHRouteDiagnosticPlanStep]) -> some View {
        HStack(spacing: 8) {
            Button {
                copy(steps.map(\.command).joined(separator: "\n"), messageKey: "ssh.diagnostic_plan.copied_all")
            } label: {
                Label(L10n.string("ssh.diagnostic_plan.copy_all"), systemImage: "doc.on.doc")
            }

            Spacer()

            Button {
                copyResultSummary(for: steps)
            } label: {
                Label(L10n.string("ssh.diagnostic_plan.copy_results"), systemImage: "checklist.checked")
            }
            .disabled(parsedResults.isEmpty)

            Button {
                parsedResults.removeAll()
                message = L10n.string("ssh.diagnostic_plan.results_cleared")
            } label: {
                Label(L10n.string("ssh.diagnostic_plan.clear_results"), systemImage: "xmark.circle")
            }
            .disabled(parsedResults.isEmpty)
        }
        .buttonStyle(.bordered)
    }

    private var emptyState: some View {
        Text(L10n.string("ssh.diagnostic_plan.empty"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var hasLocalSelectedTab: Bool {
        guard let tab = workspace.selectedTab else { return false }
        if case .localShell = tab.launchConfiguration {
            return true
        }
        return false
    }

    private var stageHelp: String {
        hasLocalSelectedTab
            ? L10n.string("ssh.diagnostic_plan.stage.help")
            : L10n.string("ssh.diagnostic_plan.stage.requires_local")
    }

    private func copy(_ text: String, messageKey: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = L10n.string(messageKey)
    }

    private func parseClipboardResult(for step: SSHRouteDiagnosticPlanStep, at index: Int) {
        guard let output = NSPasteboard.general.string(forType: .string),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = L10n.string("ssh.diagnostic_plan.parse_clipboard.empty")
            return
        }
        parsedResults[index] = step.interpretResult(exitCode: nil, output: output)
        message = L10n.string("ssh.diagnostic_plan.parse_clipboard.parsed")
    }

    private func copyResultSummary(for steps: [SSHRouteDiagnosticPlanStep]) {
        let report = SSHRouteDiagnosticReport(
            profileName: profile.displayName,
            routeSummary: profile.routeSummary,
            planSteps: steps,
            results: parsedResults
        )
        guard report.hasResults else {
            message = L10n.string("ssh.diagnostic_plan.no_results")
            return
        }
        copy(report.markdown, messageKey: "ssh.diagnostic_plan.results_copied")
    }

    private func stage(_ command: String) {
        guard let tab = workspace.selectedTab,
              case .localShell = tab.launchConfiguration else {
            message = L10n.string("ssh.diagnostic_plan.stage.requires_local")
            return
        }
        tab.startProcessIfNeeded()
        tab.controller.sendProcessInput(bytes: Array(command.utf8))
        message = L10n.string("ssh.diagnostic_plan.staged")
    }

    private func resultSummaryIcon(_ status: SSHRouteDiagnosticResultStatus?) -> String {
        switch status {
        case .passed:
            return "checkmark.seal"
        case .failed:
            return "xmark.octagon"
        case .needsAttention:
            return "exclamationmark.triangle"
        case .unknown:
            return "questionmark.circle"
        case nil:
            return "checklist"
        }
    }

    private func resultSummaryColor(_ status: SSHRouteDiagnosticResultStatus?) -> Color {
        switch status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .needsAttention:
            return .orange
        case .unknown, nil:
            return .secondary
        }
    }
}

private struct SSHRouteDiagnosticStepRow: View {
    let index: Int
    let step: SSHRouteDiagnosticPlanStep
    let skin: TerminalVisualSkin
    let result: SSHRouteDiagnosticStepResult?
    let canStage: Bool
    let stageHelp: String
    let copyAction: () -> Void
    let parseClipboardAction: () -> Void
    let stageAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(stepColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.caption.weight(.semibold))
                    metadata
                }

                Spacer()

                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("ssh.diagnostic_plan.copy_step"))

                Button(action: parseClipboardAction) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("ssh.diagnostic_plan.parse_clipboard"))

                Button(action: stageAction) {
                    Image(systemName: "terminal")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!canStage)
                .help(stageHelp)
            }

            Text(step.command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let result {
                resultView(result)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var metadata: some View {
        HStack(spacing: 5) {
            Text(kindLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(stepColor)
            if let host = step.host, !host.isEmpty {
                Text(host)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let port = step.port {
                Text(":\(port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let alias = step.alias {
                Text(alias)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func resultView(_ result: SSHRouteDiagnosticStepResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.status.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(resultColor(result.status))
                Text(result.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let evidence = result.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resultColor(result.status).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var kindLabel: String {
        switch step.kind {
        case .dnsLookup:
            return L10n.string("ssh.diagnostic_plan.kind.dns")
        case .tcpPort:
            return L10n.string("ssh.diagnostic_plan.kind.port")
        case .generatedConfig:
            return L10n.string("ssh.diagnostic_plan.kind.config")
        case .verboseRoute:
            return L10n.string("ssh.diagnostic_plan.kind.verbose")
        }
    }

    private var stepColor: Color {
        switch step.kind {
        case .dnsLookup:
            return .blue
        case .tcpPort:
            return .orange
        case .generatedConfig:
            return .purple
        case .verboseRoute:
            return .green
        }
    }

    private func resultColor(_ status: SSHRouteDiagnosticResultStatus) -> Color {
        switch status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .needsAttention:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}
