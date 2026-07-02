import AppKit
import SwiftUI

struct SSHConfigPreviewSheet: View {
    let profile: SSHConnectionProfile
    let skin: TerminalVisualSkin
    let onClose: () -> Void
    @State private var message = ""
    @State private var parsedResults: [Int: SSHRouteDiagnosticStepResult] = [:]

    private var preview: SSHConfigPreview {
        SSHConfigMaterializer.preview(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            commandSection
            configBody
            footer
        }
        .padding(18)
        .frame(width: 760, height: 640)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(skin.accent)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("ssh.config_preview.title"))
                    .font(.headline)
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("ssh.config_preview.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            EnvironmentBadge(environment: profile.environment)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            previewChip(
                title: L10n.string("ssh.config_preview.target_alias"),
                value: preview.targetAlias,
                systemImage: "scope"
            )
            previewChip(
                title: L10n.string("ssh.config_preview.host_blocks"),
                value: "\(preview.hostBlockCount)",
                systemImage: "list.bullet.rectangle"
            )
            previewChip(
                title: L10n.string("ssh.config_preview.lines"),
                value: "\(preview.lineCount)",
                systemImage: "number"
            )
        }
    }

    private func previewChip(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(skin.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var configBody: some View {
        ScrollView {
            Text(preview.config)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("ssh.config_preview.commands"))
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.string("ssh.config_preview.commands.help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 7) {
                    Button {
                        copyCommands(preview.commands)
                    } label: {
                        Label(L10n.string("ssh.config_preview.copy_commands"), systemImage: "terminal")
                    }
                    .disabled(preview.commands.isEmpty)

                    Button {
                        copyPreviewResultSummary()
                    } label: {
                        Label(L10n.string("ssh.config_preview.copy_results"), systemImage: "checklist.checked")
                    }
                    .disabled(parsedResults.isEmpty)

                    Button {
                        parsedResults.removeAll()
                        message = L10n.string("ssh.config_preview.results_cleared")
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(parsedResults.isEmpty)
                    .help(L10n.string("ssh.config_preview.clear_results"))
                }
                .buttonStyle(.bordered)
            }

            resultSummary
            recommendationCard

            VStack(spacing: 6) {
                ForEach(Array(preview.commands.enumerated()), id: \.offset) { index, command in
                    commandRow(command, index: index, result: parsedResults[index])
                }
            }
        }
        .padding(10)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var resultSummary: some View {
        let summary = SSHRouteDiagnosticResultSummary(totalSteps: preview.commands.count, results: parsedResults)
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
            } icon: {
                Image(systemName: resultSummaryIcon(summary.leadingStatus))
            }
            .foregroundStyle(resultColor(summary.leadingStatus))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(resultColor(summary.leadingStatus).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let recommendation = SSHRouteDiagnosticAdvisor.recommendation(
            planSteps: preview.commands.map(\.diagnosticStep),
            results: parsedResults
        ) {
            let detail = SSHRouteDiagnosticRecommendationDetail(
                recommendation: recommendation,
                planSteps: preview.commands.map(\.diagnosticStep),
                results: parsedResults
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: resultSummaryIcon(recommendation.status))
                        .foregroundStyle(resultColor(recommendation.status))
                    Text(recommendation.title)
                        .font(.caption.weight(.semibold))
                    if let relatedStepIndex = detail.oneBasedStepIndex {
                        Text(
                            L10n.format(
                                "ssh.config_preview.recommendation.step",
                                relatedStepIndex,
                                detail.stepTitle ?? L10n.string("ssh.diagnostic_recommendation.step.none")
                            )
                        )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(recommendation.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recommendation.action)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(resultColor(recommendation.status))
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = detail.evidence, !evidence.isEmpty {
                    recommendationContextRow(
                        title: L10n.string("ssh.config_preview.recommendation.evidence"),
                        value: evidence,
                        systemImage: "text.magnifyingglass"
                    )
                }
                if let command = detail.command, !command.isEmpty {
                    recommendationContextRow(
                        title: L10n.string("ssh.config_preview.recommendation.command"),
                        value: command,
                        systemImage: "terminal",
                        isMonospaced: true
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(resultColor(recommendation.status).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func recommendationContextRow(
        title: String,
        value: String,
        systemImage: String,
        isMonospaced: Bool = false
    ) -> some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10, design: isMonospaced ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func commandRow(
        _ command: SSHConfigPreviewCommand,
        index: Int,
        result: SSHRouteDiagnosticStepResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(command.command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    copyCommands([command])
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("ssh.diagnostic_plan.copy_step"))

                Button {
                    parseClipboardResult(for: command, at: index)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("ssh.config_preview.parse_clipboard"))
            }

            if let result {
                resultView(result)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resultColor(result.status).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footer: some View {
        HStack {
            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview.config, forType: .string)
                message = L10n.string("ssh.config_preview.copied")
            } label: {
                Label(L10n.string("ssh.config_preview.copy"), systemImage: "doc.on.doc")
            }
            Button(L10n.string("action.close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
    }

    private func copyCommands(_ commands: [SSHConfigPreviewCommand]) {
        guard !commands.isEmpty else { return }
        do {
            let materializedPreview = try SSHConfigMaterializer.writePreviewConfig(for: profile)
            let commandText = commands
                .map(\.command)
                .joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commandText, forType: .string)
            message = commands.count == materializedPreview.commands.count
                ? L10n.string("ssh.config_preview.commands_copied")
                : L10n.string("ssh.config_preview.command_copied")
        } catch {
            message = L10n.format("ssh.config_preview.write_failed", error.localizedDescription)
        }
    }

    private func parseClipboardResult(for command: SSHConfigPreviewCommand, at index: Int) {
        guard let output = NSPasteboard.general.string(forType: .string),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = L10n.string("ssh.config_preview.parse_clipboard.empty")
            return
        }
        parsedResults[index] = command.diagnosticStep.interpretResult(exitCode: nil, output: output)
        message = L10n.string("ssh.config_preview.parse_clipboard.parsed")
    }

    private func copyPreviewResultSummary() {
        let report = SSHRouteDiagnosticReport(
            profileName: profile.displayName,
            routeSummary: profile.routeSummary,
            planSteps: preview.commands.map(\.diagnosticStep),
            results: parsedResults
        )
        guard report.hasResults else {
            message = L10n.string("ssh.diagnostic_plan.no_results")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
        message = L10n.string("ssh.config_preview.results_copied")
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

    private func resultColor(_ status: SSHRouteDiagnosticResultStatus?) -> Color {
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
