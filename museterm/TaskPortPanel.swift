import AppKit
import Combine
import Foundation
import SwiftUI

struct LocalListeningPort: Identifiable, Equatable, Sendable {
    var pid: Int32
    var command: String
    var protocolName: String
    var endpoint: String
    var port: Int

    nonisolated var id: String {
        "\(pid)-\(protocolName)-\(endpoint)"
    }

    nonisolated var localURL: URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }
}

private enum LocalServiceScannerError: Error, Sendable {
    case lsofUnavailable
}

@MainActor
final class LocalServiceScanner: ObservableObject {
    @Published private(set) var ports: [LocalListeningPort] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage = ""
    @Published private(set) var updatedAt: Date?

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = ""

        Task {
            do {
                ports = try await Self.scanListeningPorts()
                updatedAt = Date()
            } catch {
                if let scannerError = error as? LocalServiceScannerError {
                    errorMessage = scannerError.localizedMessage
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isScanning = false
        }
    }

    private static func scanListeningPorts() async throws -> [LocalListeningPort] {
        try await Task.detached {
            try runLsof()
        }.value
    }

    private nonisolated static func runLsof() throws -> [LocalListeningPort] {
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalServiceScannerError.lsofUnavailable
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPn"]
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0, data.isEmpty {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                throw NSError(
                    domain: "MuseTerm.LocalServiceScanner",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            return []
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return parseLsofFields(text)
    }

    private nonisolated static func parseLsofFields(_ text: String) -> [LocalListeningPort] {
        var currentPID: Int32?
        var currentCommand = ""
        var currentProtocol = "TCP"
        var seen = Set<String>()
        var ports: [LocalListeningPort] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
                currentProtocol = "TCP"
            case "c":
                currentCommand = value
            case "P":
                currentProtocol = value
            case "n":
                guard let currentPID,
                      let port = extractPort(from: value) else {
                    continue
                }
                let record = LocalListeningPort(
                    pid: currentPID,
                    command: currentCommand,
                    protocolName: currentProtocol.isEmpty ? "TCP" : currentProtocol,
                    endpoint: value,
                    port: port
                )
                guard seen.insert(record.id).inserted else { continue }
                ports.append(record)
            default:
                continue
            }
        }

        return ports.sorted { left, right in
            if left.port != right.port {
                return left.port < right.port
            }
            if left.command != right.command {
                return left.command.localizedCaseInsensitiveCompare(right.command) == .orderedAscending
            }
            return left.pid < right.pid
        }
    }

    private nonisolated static func extractPort(from endpoint: String) -> Int? {
        guard let separator = endpoint.lastIndex(of: ":") else { return nil }
        let suffix = endpoint[endpoint.index(after: separator)...]
        let digits = suffix.prefix { $0.isNumber }
        guard let port = Int(digits), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}

private extension LocalServiceScannerError {
    var localizedMessage: String {
        switch self {
        case .lsofUnavailable:
            return L10n.string("task_panel.error_lsof_unavailable")
        }
    }
}

struct TaskPortPanelView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences
    @Binding var isVisible: Bool
    @StateObject private var scanner = LocalServiceScanner()
    @StateObject private var dailyStatsStore = PersistentCommandStatsStore()
    @State private var message = ""
    @State private var processPIDText = ""
    private let statsRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var runningBlocks: [(tab: TerminalSession, block: TerminalCommandBlock)] {
        workspace.tabs.flatMap { tab in
            tab.commandBlocks
                .filter { $0.endedAt == nil }
                .map { (tab: tab, block: $0) }
        }
    }

    private var allCommandBlocks: [TerminalCommandBlock] {
        workspace.tabs.flatMap(\.commandBlocks)
    }

    private var stats: SessionCommandStats {
        SessionCommandStats(
            blocks: allCommandBlocks,
            portCount: scanner.ports.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.45)
            content
        }
        .frame(width: 340)
        .background(preferences.skin.sidebarBackground)
        .onAppear {
            scanner.refresh()
            dailyStatsStore.record(blocks: allCommandBlocks)
        }
        .onReceive(statsRefreshTimer) { _ in
            dailyStatsStore.record(blocks: allCommandBlocks)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(preferences.skin.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("task_panel.title"))
                    .font(.headline)
                Text(L10n.string("task_panel.subtitle"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                scanner.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(scanner.isScanning)
            .help(L10n.string("task_panel.refresh"))

            Button {
                isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.string("action.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusPanel
                sessionStatsSection
                dailyStatsSection
                runningCommandsSection
                sessionProcessToolsSection
                listeningPortsSection
            }
            .padding(12)
        }
    }

    private var sessionStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("stats.title", count: stats.commandCount)
            if stats.commandCount == 0, stats.portCount == 0 {
                emptyLine("stats.empty")
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    StatTile(titleKey: "stats.commands", value: "\(stats.commandCount)", skin: preferences.skin)
                    StatTile(titleKey: "stats.failures", value: "\(stats.failureCount)", skin: preferences.skin)
                    StatTile(titleKey: "stats.running", value: "\(stats.runningCount)", skin: preferences.skin)
                    StatTile(titleKey: "stats.ports", value: "\(stats.portCount)", skin: preferences.skin)
                }
                if let longestDuration = stats.longestDurationMilliseconds {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text(L10n.format("stats.longest_duration", formatDuration(longestDuration)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let recentFailureDiagnostic = stats.recentFailureDiagnostic {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L10n.format("stats.recent_failure", recentFailureDiagnostic))
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let repeatedFailureDiagnostic = stats.repeatedFailureDiagnostic {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "repeat")
                        Text(
                            L10n.format(
                                "stats.repeated_failure",
                                repeatedFailureDiagnostic.count,
                                repeatedFailureDiagnostic.diagnostic
                            )
                        )
                        .lineLimit(3)
                        .textSelection(.enabled)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if !stats.achievements.isEmpty {
                    FlowBadgeRow(achievements: stats.achievements, skin: preferences.skin)
                }
            }
        }
    }

    private var dailyStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("stats.today_title", count: dailyStatsStore.today.commandCount)
            if dailyStatsStore.today.commandCount == 0 {
                emptyLine("stats.today_empty")
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    StatTile(titleKey: "stats.commands", value: "\(dailyStatsStore.today.commandCount)", skin: preferences.skin)
                    StatTile(titleKey: "stats.failures", value: "\(dailyStatsStore.today.failureCount)", skin: preferences.skin)
                }
                if let longestDuration = dailyStatsStore.today.longestDurationMilliseconds {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text(L10n.format("stats.longest_duration", formatDuration(longestDuration)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if scanner.isScanning || !scanner.errorMessage.isEmpty || !message.isEmpty || scanner.updatedAt != nil {
            VStack(alignment: .leading, spacing: 5) {
                if scanner.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.55)
                        Text(L10n.string("task_panel.scanning"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let updatedAt = scanner.updatedAt, !scanner.isScanning {
                    Text(L10n.format("task_panel.updated", Self.timeFormatter.string(from: updatedAt)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !scanner.errorMessage.isEmpty {
                    Text(scanner.errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(preferences.skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(preferences.skin.hairline, lineWidth: 1)
            )
        }
    }

    private var runningCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("task_panel.running_commands", count: runningBlocks.count)
            if runningBlocks.isEmpty {
                emptyLine("task_panel.no_running_commands")
            } else {
                ForEach(runningBlocks, id: \.block.id) { item in
                    RunningCommandRow(tab: item.tab, block: item.block, skin: preferences.skin)
                }
            }
        }
    }

    private var listeningPortsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("task_panel.local_ports", count: scanner.ports.count)
            if scanner.ports.isEmpty, !scanner.isScanning {
                emptyLine("task_panel.no_ports")
            } else {
                ForEach(scanner.ports) { port in
                    ListeningPortRow(
                        port: port,
                        skin: preferences.skin,
                        openLocalURL: { openLocalURL(port) },
                        copyEndpoint: { copyEndpoint(port) },
                        stageKill: { stageKill(port.pid) }
                    )
                }
            }
        }
    }

    private var sessionProcessToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("task_panel.session_tools", count: workspace.selectedTab == nil ? 0 : 1)
            if let selectedTab = workspace.selectedTab {
                Text(L10n.format("task_panel.session_tools_target", selectedTab.tabTitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    toolButton("task_panel.stage_port_scan", systemImage: "network") {
                        stageCommand(CurrentSessionProcessCommand.portScan.command)
                    }
                    toolButton("task_panel.stage_process_list", systemImage: "list.bullet.rectangle") {
                        stageCommand(CurrentSessionProcessCommand.processList.command)
                    }
                }

                HStack(spacing: 8) {
                    TextField(L10n.string("task_panel.pid_placeholder"), text: $processPIDText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospacedDigit())
                    toolButton("task_panel.stage_pid_details", systemImage: "info.circle") {
                        stagePIDCommand(.details)
                    }
                    toolButton("task_panel.stage_pid_term", systemImage: "xmark.circle") {
                        stagePIDCommand(.term)
                    }
                    toolButton("task_panel.stage_pid_kill", systemImage: "xmark.octagon") {
                        stagePIDCommand(.kill)
                    }
                }
            } else {
                emptyLine("task_panel.no_session_tools_target")
            }
        }
    }

    private func toolButton(_ helpKey: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .help(L10n.string(helpKey))
    }

    private func sectionTitle(_ key: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(L10n.string(key))
                .font(.caption.weight(.semibold))
            Text(verbatim: "\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func emptyLine(_ key: String) -> some View {
        Text(L10n.string(key))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private func openLocalURL(_ port: LocalListeningPort) {
        guard let url = port.localURL else { return }
        NSWorkspace.shared.open(url)
        message = L10n.format("task_panel.opened_url", url.absoluteString)
    }

    private func copyEndpoint(_ port: LocalListeningPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port.endpoint, forType: .string)
        message = L10n.string("task_panel.copied_endpoint")
    }

    private func stageKill(_ pid: Int32) {
        guard let tab = workspace.selectedTab,
              case .localShell = tab.launchConfiguration else {
            message = L10n.string("task_panel.local_kill_requires_local_tab")
            return
        }
        tab.startProcessIfNeeded()
        tab.controller.sendProcessInput(bytes: Array("kill \(pid)".utf8))
        message = L10n.format("task_panel.kill_staged", Int(pid))
    }

    private func stagePIDCommand(_ action: CurrentSessionProcessCommand.PIDAction) {
        let trimmed = processPIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else {
            message = L10n.string("task_panel.invalid_pid")
            return
        }
        stageCommand(CurrentSessionProcessCommand.pid(pid, action: action).command)
    }

    private func stageCommand(_ command: String) {
        guard let tab = workspace.selectedTab else { return }
        tab.startProcessIfNeeded()
        tab.controller.sendProcessInput(bytes: Array(command.utf8))
        message = L10n.string("task_panel.command_staged")
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        let seconds = milliseconds / 1_000
        if seconds < 60 {
            return "\(seconds) s"
        }
        let minutes = seconds / 60
        return "\(minutes) min \(seconds % 60) s"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private enum CurrentSessionProcessCommand {
    enum PIDAction {
        case details
        case term
        case kill
    }

    case portScan
    case processList
    case pid(Int, action: PIDAction)

    var command: String {
        switch self {
        case .portScan:
            return """
            if command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN; elif command -v ss >/dev/null 2>&1; then ss -ltnp; elif command -v netstat >/dev/null 2>&1; then netstat -ltnp 2>/dev/null || netstat -anv | grep LISTEN; else echo 'No lsof, ss, or netstat found.'; fi
            """
        case .processList:
            return "ps -eo pid,ppid,stat,%cpu,%mem,command | head -40"
        case .pid(let pid, .details):
            return "ps -p \(pid) -o pid,ppid,stat,%cpu,%mem,etime,command"
        case .pid(let pid, .term):
            return "kill -TERM \(pid)"
        case .pid(let pid, .kill):
            return "kill -KILL \(pid)"
        }
    }
}

struct SessionCommandStats {
    let commandCount: Int
    let failureCount: Int
    let runningCount: Int
    let portCount: Int
    let longestDurationMilliseconds: Int?
    let recentFailureDiagnostic: String?
    let repeatedFailureDiagnostic: RepeatedFailureDiagnostic?

    init(blocks: [TerminalCommandBlock], portCount: Int) {
        commandCount = blocks.count
        let diagnostics = CommandBlockDiagnostics(blocks: blocks)
        failureCount = diagnostics.failedCommandCount
        runningCount = blocks.filter { $0.endedAt == nil }.count
        self.portCount = portCount
        longestDurationMilliseconds = blocks.compactMap(\.durationMilliseconds).max()
        recentFailureDiagnostic = diagnostics.recentFailureDiagnostic
        repeatedFailureDiagnostic = diagnostics.repeatedFailureDiagnostic
    }

    var achievements: [String] {
        var result: [String] = []
        if commandCount >= 10 {
            result.append(L10n.string("stats.achievement.ten_commands"))
        }
        if commandCount > 0, failureCount == 0 {
            result.append(L10n.string("stats.achievement.clean_run"))
        }
        if portCount > 0 {
            result.append(L10n.string("stats.achievement.service_online"))
        }
        if (longestDurationMilliseconds ?? 0) >= 60_000 {
            result.append(L10n.string("stats.achievement.long_runner"))
        }
        return result
    }

}

struct CommandBlockDiagnostics: Equatable {
    let failedCommandCount: Int
    let latestFailedCommand: String?
    let recentFailureDiagnostic: String?
    let recentFailureFingerprint: String?
    let repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    let suggestedNextInspection: String?
    let diagnosticSeverity: CommandDiagnosticSeverity

    init(blocks: [TerminalCommandBlock], redactSensitiveData: Bool = true) {
        let failedBlocks = blocks.filter(Self.isFailed).sorted(by: Self.mostRecentFirst)
        failedCommandCount = failedBlocks.count
        latestFailedCommand = failedBlocks.first.map { block in
            let command = block.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return redactSensitiveData ? RunbookSensitiveRedactor.redact(command) : command
        }
        let recentFailureRecord = failedBlocks
            .sorted(by: Self.mostRecentFirst)
            .compactMap { Self.failureDiagnosticRecord(for: $0, redactSensitiveData: redactSensitiveData) }
            .first
        recentFailureDiagnostic = recentFailureRecord?.diagnostic
        recentFailureFingerprint = recentFailureRecord?.fingerprint
        repeatedFailureDiagnostic = Self.repeatedFailureDiagnostic(
            in: blocks,
            redactSensitiveData: redactSensitiveData
        )
        diagnosticSeverity = Self.diagnosticSeverity(
            failedCommandCount: failedCommandCount,
            recentFailureDiagnostic: recentFailureDiagnostic,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
        suggestedNextInspection = Self.suggestedNextInspection(
            failedCommandCount: failedCommandCount,
            latestFailedCommand: latestFailedCommand,
            recentFailureDiagnostic: recentFailureDiagnostic,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
    }

    var aiContextText: String? {
        var lines: [String] = []
        if failedCommandCount > 0 {
            lines.append("Failed commands: \(failedCommandCount)")
        }
        if let latestFailedCommand {
            lines.append("Latest failed command: \(latestFailedCommand)")
        }
        if let recentFailureDiagnostic {
            lines.append("Recent failure diagnostic: \(recentFailureDiagnostic)")
        }
        if let recentFailureFingerprint {
            lines.append("Recent failure fingerprint: \(recentFailureFingerprint)")
        }
        if let repeatedFailureDiagnostic {
            lines.append(
                "Repeated failure diagnostic: \(repeatedFailureDiagnostic.count)x \(repeatedFailureDiagnostic.diagnostic)"
            )
            lines.append(
                "Repeated failure window: \(Self.isoTimestamp(repeatedFailureDiagnostic.firstOccurredAt)) to \(Self.isoTimestamp(repeatedFailureDiagnostic.latestOccurredAt))"
            )
        }
        if diagnosticSeverity != .none {
            lines.append("Diagnostic severity: \(diagnosticSeverity.rawValue)")
        }
        if let suggestedNextInspection {
            lines.append("Suggested next inspection: \(suggestedNextInspection)")
        }
        guard !lines.isEmpty else { return nil }
        return (["Session diagnostics:"] + lines).joined(separator: "\n")
    }

    nonisolated static func mostRecentFirst(_ left: TerminalCommandBlock, _ right: TerminalCommandBlock) -> Bool {
        (left.endedAt ?? left.startedAt) > (right.endedAt ?? right.startedAt)
    }

    nonisolated static func isFailed(_ block: TerminalCommandBlock) -> Bool {
        guard block.endedAt != nil, let exitCode = block.exitCode else { return false }
        return exitCode != 0
    }

    nonisolated private static func failureDiagnostic(
        for block: TerminalCommandBlock,
        redactSensitiveData: Bool
    ) -> String? {
        let diagnostic = block.outputSummary?.primaryDiagnosticLine
            ?? TerminalOutputInsightAnalyzer.outputSummary(in: block.outputTail)?.primaryDiagnosticLine
        guard let diagnostic else { return nil }
        let cleaned = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return redactSensitiveData ? RunbookSensitiveRedactor.redact(cleaned) : cleaned
    }

    nonisolated private static func failureDiagnosticRecord(
        for block: TerminalCommandBlock,
        redactSensitiveData: Bool
    ) -> FailureDiagnosticRecord? {
        guard let diagnostic = failureDiagnostic(for: block, redactSensitiveData: redactSensitiveData) else {
            return nil
        }
        return FailureDiagnosticRecord(
            diagnostic: diagnostic,
            fingerprint: failureDiagnosticFingerprint(for: diagnostic)
        )
    }

    nonisolated private static func failureDiagnosticFingerprint(for diagnostic: String) -> String {
        let redacted = RunbookSensitiveRedactor.redact(diagnostic)
        var normalized = redacted.lowercased()
        let replacements: [(pattern: String, value: String)] = [
            (#"https?://\S+"#, "<url>"),
            (#"\b[\w.%+-]+@[\w.-]+\.[a-z]{2,}\b"#, "<email>"),
            (#"(?:/[a-z0-9._~+\-]+)+"#, "<path>"),
            (#"[a-z]:\\[^\s]+"#, "<path>"),
            (#"\b0x[0-9a-f]+\b"#, "<hex>"),
            (#"\b[0-9a-f]{7,40}\b"#, "<hash>"),
            (#"\b\d+(?:\.\d+)?\b"#, "<num>"),
            (#"\s+"#, " ")
        ]
        for replacement in replacements {
            normalized = normalized.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.value,
                options: .regularExpression
            )
        }
        return String(normalized.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }

    nonisolated private static func repeatedFailureDiagnostic(
        in blocks: [TerminalCommandBlock],
        redactSensitiveData: Bool
    ) -> RepeatedFailureDiagnostic? {
        let endedBlocks = blocks
            .filter { $0.endedAt != nil }
            .sorted(by: mostRecentFirst)
        guard let latest = endedBlocks.first,
              isFailed(latest),
              let latestRecord = failureDiagnosticRecord(for: latest, redactSensitiveData: redactSensitiveData) else {
            return nil
        }

        var count = 0
        var matchedBlocks: [TerminalCommandBlock] = []
        for block in endedBlocks {
            guard isFailed(block),
                  failureDiagnosticRecord(for: block, redactSensitiveData: redactSensitiveData)?.fingerprint == latestRecord.fingerprint else {
                break
            }
            count += 1
            matchedBlocks.append(block)
        }
        guard count >= Self.repeatedFailureThreshold,
              let latestMatchedBlock = matchedBlocks.first,
              let firstMatchedBlock = matchedBlocks.last else {
            return nil
        }
        return RepeatedFailureDiagnostic(
            diagnostic: latestRecord.diagnostic,
            fingerprint: latestRecord.fingerprint,
            firstOccurredAt: occurrenceDate(for: firstMatchedBlock),
            latestOccurredAt: occurrenceDate(for: latestMatchedBlock),
            count: count
        )
    }

    nonisolated private static func diagnosticSeverity(
        failedCommandCount: Int,
        recentFailureDiagnostic: String?,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    ) -> CommandDiagnosticSeverity {
        guard failedCommandCount > 0 else { return .none }
        let diagnostic = recentFailureDiagnostic?.lowercased() ?? ""
        if diagnostic.contains("fatal")
            || diagnostic.contains("panic")
            || diagnostic.contains("segmentation fault")
            || diagnostic.contains("permission denied") {
            return .critical
        }
        if repeatedFailureDiagnostic != nil {
            return .repeated
        }
        return .failed
    }

    nonisolated private static func suggestedNextInspection(
        failedCommandCount: Int,
        latestFailedCommand: String?,
        recentFailureDiagnostic: String?,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    ) -> String? {
        if let repeatedFailureDiagnostic {
            return "Inspect the repeated failure output before rerunning: \(repeatedFailureDiagnostic.diagnostic)"
        }
        if let recentFailureDiagnostic {
            return "Inspect the latest failed command output: \(recentFailureDiagnostic)"
        }
        if failedCommandCount > 0, let latestFailedCommand {
            return "Inspect the latest failed command exit status: \(latestFailedCommand)"
        }
        return nil
    }

    nonisolated private static func occurrenceDate(for block: TerminalCommandBlock) -> Date {
        block.endedAt ?? block.startedAt
    }

    nonisolated private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated private static let repeatedFailureThreshold = 3
}

struct RepeatedFailureDiagnostic: Equatable {
    let diagnostic: String
    let fingerprint: String
    let firstOccurredAt: Date
    let latestOccurredAt: Date
    let count: Int
}

enum CommandDiagnosticSeverity: String, Codable, Equatable {
    case none
    case failed
    case repeated
    case critical
}

private struct FailureDiagnosticRecord: Equatable {
    let diagnostic: String
    let fingerprint: String
}

private struct PersistentCommandStatsSnapshot: Codable, Equatable {
    var dateKey: String
    var commandCount: Int
    var failureCount: Int
    var longestDurationMilliseconds: Int?
    var countedCommandIDs: Set<String>

    static func empty(dateKey: String = Self.currentDateKey()) -> PersistentCommandStatsSnapshot {
        PersistentCommandStatsSnapshot(
            dateKey: dateKey,
            commandCount: 0,
            failureCount: 0,
            longestDurationMilliseconds: nil,
            countedCommandIDs: []
        )
    }

    static func currentDateKey(date: Date = Date()) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
private final class PersistentCommandStatsStore: ObservableObject {
    @Published private(set) var today: PersistentCommandStatsSnapshot = .empty()

    init() {
        today = loadToday()
    }

    func record(blocks: [TerminalCommandBlock]) {
        var snapshot = loadToday()
        var didChange = false

        for block in blocks where block.endedAt != nil {
            let id = block.id.uuidString
            guard snapshot.countedCommandIDs.insert(id).inserted else { continue }
            snapshot.commandCount += 1
            if let exitCode = block.exitCode, exitCode != 0 {
                snapshot.failureCount += 1
            }
            if let duration = block.durationMilliseconds {
                snapshot.longestDurationMilliseconds = max(snapshot.longestDurationMilliseconds ?? 0, duration)
            }
            didChange = true
        }

        if didChange {
            save(snapshot)
        }
        if today != snapshot {
            today = snapshot
        }
    }

    private func loadToday() -> PersistentCommandStatsSnapshot {
        let currentKey = PersistentCommandStatsSnapshot.currentDateKey()
        guard let url = try? Self.statsURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistentCommandStatsSnapshot.self, from: data),
              snapshot.dateKey == currentKey else {
            return .empty(dateKey: currentKey)
        }
        return snapshot
    }

    private func save(_ snapshot: PersistentCommandStatsSnapshot) {
        do {
            let url = try Self.statsURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Local statistics are best-effort; terminal work should never be blocked by persistence.
        }
    }

    private static func statsURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("Stats", isDirectory: true)
            .appendingPathComponent("daily-command-stats.json")
    }
}

private struct StatTile: View {
    let titleKey: String
    let value: String
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
            Text(L10n.string(titleKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }
}

private struct FlowBadgeRow: View {
    let achievements: [String]
    let skin: TerminalVisualSkin

    var body: some View {
        WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(achievements, id: \.self) { achievement in
                Text(achievement)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(skin.selectionFill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(skin.hairline, lineWidth: 1)
                    )
            }
        }
    }
}

private struct WrappingHStack<Content: View>: View {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 13.0, *) {
            Layout(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
                content
            }
        }
    }

    private struct Layout: SwiftUI.Layout {
        let horizontalSpacing: CGFloat
        let verticalSpacing: CGFloat

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            rows(in: proposal.width ?? 0, subviews: subviews).size
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {
            let computedRows = rows(in: bounds.width, subviews: subviews)
            var y = bounds.minY
            for row in computedRows.rows {
                var x = bounds.minX
                for item in row.items {
                    item.subview.place(
                        at: CGPoint(x: x, y: y),
                        proposal: ProposedViewSize(item.size)
                    )
                    x += item.size.width + horizontalSpacing
                }
                y += row.height + verticalSpacing
            }
        }

        private func rows(in width: CGFloat, subviews: Subviews) -> (rows: [Row], size: CGSize) {
            var rows: [Row] = []
            var currentItems: [RowItem] = []
            var currentWidth: CGFloat = 0
            var currentHeight: CGFloat = 0
            let availableWidth = max(width, 1)

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                let nextWidth = currentItems.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width
                if nextWidth > availableWidth, !currentItems.isEmpty {
                    rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                    currentItems = []
                    currentWidth = 0
                    currentHeight = 0
                }

                currentItems.append(RowItem(subview: subview, size: size))
                currentWidth = currentItems.count == 1 ? size.width : currentWidth + horizontalSpacing + size.width
                currentHeight = max(currentHeight, size.height)
            }

            if !currentItems.isEmpty {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
            }

            let totalHeight = rows.reduce(CGFloat(0)) { partial, row in
                partial + row.height
            } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
            let totalWidth = rows.map(\.width).max() ?? 0
            return (rows, CGSize(width: totalWidth, height: totalHeight))
        }

        private struct Row {
            let items: [RowItem]
            let width: CGFloat
            let height: CGFloat
        }

        private struct RowItem {
            let subview: LayoutSubview
            let size: CGSize
        }
    }
}

private struct RunningCommandRow: View {
    @ObservedObject var tab: TerminalSession
    let block: TerminalCommandBlock
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(skin.accent)
                    .frame(width: 6, height: 6)
                Text(tab.tabTitle)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.timeFormatter.string(from: block.startedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(block.command)
                .font(.caption.monospaced())
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let workingDirectory = block.workingDirectory, !workingDirectory.isEmpty {
                    Label(URL(fileURLWithPath: workingDirectory).lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                Label("\(block.outputCharacterCount)", systemImage: "text.alignleft")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct ListeningPortRow: View {
    let port: LocalListeningPort
    let skin: TerminalVisualSkin
    let openLocalURL: () -> Void
    let copyEndpoint: () -> Void
    let stageKill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: ":\(port.port)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(skin.accent)
                Text(processName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(verbatim: "PID \(port.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(port.endpoint)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: openLocalURL) {
                    Image(systemName: "safari")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("task_panel.open_localhost"))

                Button(action: copyEndpoint) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("task_panel.copy_endpoint"))

                Button(action: stageKill) {
                    Image(systemName: "xmark.octagon")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("task_panel.stage_kill"))

                Spacer()
                Text(port.protocolName)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }

    private var processName: String {
        port.command.isEmpty ? L10n.string("task_panel.unknown_process") : port.command
    }
}
