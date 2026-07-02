import AppKit
import SwiftUI

struct SSHRouteDiagnosticPlanSheet: View {
    let profile: SSHConnectionProfile
    @ObservedObject var workspace: TerminalWorkspace
    let skin: TerminalVisualSkin
    let onClose: () -> Void
    @State private var message = ""

    private var plan: SSHRouteDiagnosticPlan? {
        SSHRouteProbeGuideBuilder.plan(for: profile, issue: .connectionTimedOut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let plan {
                routeSummary(plan.routeSummary)
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

    private func stepList(_ steps: [SSHRouteDiagnosticPlanStep]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    SSHRouteDiagnosticStepRow(
                        index: index + 1,
                        step: step,
                        skin: skin,
                        canStage: hasLocalSelectedTab,
                        stageHelp: stageHelp,
                        copyAction: { copy(step.command, messageKey: "ssh.diagnostic_plan.copied_step") },
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
}

private struct SSHRouteDiagnosticStepRow: View {
    let index: Int
    let step: SSHRouteDiagnosticPlanStep
    let skin: TerminalVisualSkin
    let canStage: Bool
    let stageHelp: String
    let copyAction: () -> Void
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
}
