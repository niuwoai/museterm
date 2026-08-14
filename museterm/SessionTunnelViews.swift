import AppKit
import SwiftUI

struct SessionTunnelCreateSheet: View {
    @ObservedObject var tab: TerminalSession
    let presets: [SessionTunnelPreset]
    @Binding var isPresented: Bool
    let onStart: (SessionTunnelConfiguration) throws -> Void

    @State private var name = "MySQL"
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = 3306
    @State private var localPort = 13306
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            currentSession
            endpointFields
            safetyNote
            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(22)
        .frame(width: 580)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("session_tunnel.create.title"))
                .font(.title3.weight(.semibold))
            Text(L10n.string("session_tunnel.create.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var currentSession: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("session_tunnel.current_session"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Label(sessionIdentity, systemImage: "terminal")
                .font(.callout.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var endpointFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !presets.isEmpty {
                recentPresets
            }
            endpointRow(
                titleKey: "session_tunnel.remote_target",
                host: $targetHost,
                port: $targetPort,
                hostHelpKey: "session_tunnel.remote_target.help",
                hostIdentifier: "sessionTunnelTargetHost",
                portIdentifier: "sessionTunnelTargetPort"
            )
            HStack(spacing: 10) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.secondary)
                Divider()
            }
            endpointRow(
                titleKey: "session_tunnel.local_listener",
                host: .constant("127.0.0.1"),
                port: $localPort,
                hostHelpKey: "session_tunnel.local_listener.help",
                hostDisabled: true,
                hostIdentifier: "sessionTunnelLocalHost",
                portIdentifier: "sessionTunnelLocalPort"
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("session_tunnel.name"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.string("session_tunnel.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sessionTunnelName")
            }
        }
    }

    private var recentPresets: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string("session_tunnel.recent_presets"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name.isEmpty ? L10n.string("session_tunnel.default_name") : preset.name)
                                    .font(.caption.weight(.semibold))
                                Text("\(preset.targetHost):\(preset.targetPort) → 127.0.0.1:\(preset.localPort)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sessionTunnelPreset-\(preset.id.uuidString)")
                    }
                }
            }
        }
    }

    private func apply(_ preset: SessionTunnelPreset) {
        name = preset.name
        targetHost = preset.targetHost
        targetPort = preset.targetPort
        localPort = preset.localPort
        errorMessage = ""
    }

    private func endpointRow(
        titleKey: String,
        host: Binding<String>,
        port: Binding<Int>,
        hostHelpKey: String,
        hostDisabled: Bool = false,
        hostIdentifier: String,
        portIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(L10n.string("session_tunnel.host"), text: host)
                    .textFieldStyle(.roundedBorder)
                    .disabled(hostDisabled)
                    .accessibilityIdentifier(hostIdentifier)
                Text(verbatim: ":")
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.string("session_tunnel.port"),
                    value: port,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 112)
                .accessibilityIdentifier(portIdentifier)
            }
            Text(L10n.string(hostHelpKey))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                L10n.string("session_tunnel.loopback_only"),
                systemImage: "lock.shield.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            Text(L10n.string("session_tunnel.create.terminal_notice"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack {
            Button(L10n.string("action.cancel")) {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L10n.string("session_tunnel.start")) {
                startTunnel()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sessionTunnelStartButton")
        }
    }

    private var sessionIdentity: String {
        let context = tab.executionContext
        let user = context.normalizedUser ?? L10n.string("session_tunnel.unknown_user")
        let host = context.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = host?.isEmpty == false ? host! : context.displayTarget
        return "\(tab.tabTitle) · \(user)@\(target)"
    }

    private func startTunnel() {
        do {
            let configuration = SessionTunnelConfiguration(
                name: name,
                targetHost: targetHost,
                targetPort: targetPort,
                localPort: localPort
            )
            try onStart(configuration)
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SessionTunnelMaskView: View {
    let status: SessionTunnelStatus
    let skin: TerminalVisualSkin

    var body: some View {
        ZStack {
            Color(nsColor: skin.terminalBackground)
                .opacity(0.82)
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "link")
                        .font(.title2.weight(.medium))
                    Circle()
                        .fill(status.phase == .failed ? Color.red : Color.green)
                        .frame(width: 10, height: 10)
                    Text(maskTitle)
                        .font(.title3.weight(.semibold))
                }
                Text(maskSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(maskTitle)
        .accessibilityValue(maskSummary)
        .accessibilityIdentifier("sessionTunnelMask")
    }

    private var maskTitle: String {
        switch status.phase {
        case .starting:
            return L10n.string("session_tunnel.mask.starting")
        case .running:
            return L10n.string("session_tunnel.mask.running")
        case .stopping:
            return L10n.string("session_tunnel.mask.stopping")
        case .failed:
            return L10n.string("session_tunnel.mask.failed")
        }
    }

    private var maskSummary: String {
        L10n.string("session_tunnel.mask.summary")
    }
}

struct SessionTunnelMaskContainer: View {
    @ObservedObject var tab: TerminalSession
    let skin: TerminalVisualSkin

    @ViewBuilder
    var body: some View {
        if let status = tab.sessionTunnelStatus, status.occupiesTerminal {
            SessionTunnelMaskView(status: status, skin: skin)
                .transition(.opacity)
        }
    }
}

struct SessionTunnelInspectorView: View {
    @ObservedObject var tab: TerminalSession
    @ObservedObject var preferences: TerminalPreferences
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let status = tab.sessionTunnelStatus {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        serviceHeader(status)
                        route(status)
                        metrics(status)
                        connections(status)
                        if let error = status.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("sessionTunnelError")
                        }
                    }
                    .padding(14)
                }
                Divider()
                footer(status)
            }
        }
        .frame(width: 324)
        .background(preferences.skin.sidebarBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(preferences.skin.hairline)
                .frame(width: 1)
        }
        .onChange(of: tab.sessionTunnelStatus) { status in
            if status == nil {
                onDismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(preferences.skin.accent)
            Text(L10n.string("session_tunnel.title"))
                .font(.headline)
                .accessibilityIdentifier("sessionTunnelInspector")
            Spacer()
            Image(systemName: "pin")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func serviceHeader(_ status: SessionTunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(phaseTitle(status.phase), systemImage: phaseSymbol(status.phase))
                .font(.callout.weight(.semibold))
                .foregroundStyle(phaseColor(status.phase))
                .accessibilityIdentifier("sessionTunnelPhase.\(status.phase.rawValue)")
            Label(status.configuration.displayName, systemImage: "cylinder.split.1x2")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(preferences.skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(preferences.skin.hairline, lineWidth: 1)
                }
        }
    }

    private func route(_ status: SessionTunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            routeStop(
                titleKey: "session_tunnel.route.local",
                value: status.configuration.localEndpoint,
                symbol: "desktopcomputer",
                copyValue: status.configuration.localEndpoint
            )
            Divider().padding(.leading, 13)
            routeStop(
                titleKey: "session_tunnel.route.session",
                value: sessionIdentity,
                symbol: "terminal"
            )
            Divider().padding(.leading, 13)
            routeStop(
                titleKey: "session_tunnel.route.remote",
                value: status.configuration.remoteEndpoint,
                symbol: "server.rack"
            )
        }
    }

    private func routeStop(
        titleKey: String,
        value: String,
        symbol: String,
        copyValue: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(titleKey))
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(L10n.string("session_tunnel.copy_local_endpoint"))
                .accessibilityLabel(L10n.string("session_tunnel.copy_local_endpoint"))
            }
        }
    }

    private func metrics(_ status: SessionTunnelStatus) -> some View {
        VStack(spacing: 0) {
            metricRow(titleKey: "session_tunnel.uptime") {
                if let startedAt = status.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(Self.durationText(from: startedAt, to: timeline.date))
                            .monospacedDigit()
                    }
                } else {
                    Text(verbatim: "—")
                }
            }
            Divider()
            metricRow(titleKey: "session_tunnel.transferred") {
                Text(Self.byteCountFormatter.string(fromByteCount: status.totalTransferredBytes))
                    .monospacedDigit()
            }
        }
        .background(preferences.skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(preferences.skin.hairline, lineWidth: 1)
        }
    }

    private func metricRow<Content: View>(
        titleKey: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack {
            Text(L10n.string(titleKey))
                .font(.caption)
            Spacer()
            value()
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func connections(_ status: SessionTunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("session_tunnel.connections"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(verbatim: "\(status.clients.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if status.clients.isEmpty {
                Text(L10n.string("session_tunnel.connections.empty"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(status.clients) { client in
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(preferences.skin.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.endpoint)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Text(Self.connectionTraffic(client))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func footer(_ status: SessionTunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.occupiesTerminal {
                Label(
                    L10n.string("session_tunnel.close_tab_warning"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button(role: .destructive) {
                    tab.stopSessionTunnel()
                } label: {
                    Text(L10n.string("session_tunnel.stop"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessionTunnelStopButton")
            } else {
                Button {
                    tab.updateSessionTunnelStatus(nil)
                } label: {
                    Text(L10n.string("action.close"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
    }

    private var sessionIdentity: String {
        let context = tab.executionContext
        let user = context.normalizedUser ?? L10n.string("session_tunnel.unknown_user")
        let host = context.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = host?.isEmpty == false ? host! : context.displayTarget
        return "\(tab.tabTitle) · \(user)@\(target)"
    }

    private func phaseTitle(_ phase: SessionTunnelPhase) -> String {
        L10n.string("session_tunnel.phase.\(phase.rawValue)")
    }

    private func phaseSymbol(_ phase: SessionTunnelPhase) -> String {
        switch phase {
        case .starting: return "hourglass"
        case .running: return "circle.fill"
        case .stopping: return "stopwatch"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func phaseColor(_ phase: SessionTunnelPhase) -> Color {
        switch phase {
        case .starting, .stopping: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter
    }()

    private static func durationText(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func connectionTraffic(_ client: SessionTunnelClientSnapshot) -> String {
        let uploaded = byteCountFormatter.string(fromByteCount: client.uploadedBytes)
        let downloaded = byteCountFormatter.string(fromByteCount: client.downloadedBytes)
        return L10n.format("session_tunnel.connection_traffic", uploaded, downloaded)
    }
}
