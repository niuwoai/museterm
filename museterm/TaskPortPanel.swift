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
    let diagnosticPriorityScore: Int
    let diagnosticPriorityFactors: [CommandDiagnosticPriorityFactor]
    let latestFailedCommand: String?
    let recentFailureDiagnostic: String?
    let recentFailureFingerprint: String?
    let repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    let suggestedNextInspection: String?
    let suggestedNextCommand: String?
    let diagnosticSeverity: CommandDiagnosticSeverity
    let diagnosticCategory: CommandDiagnosticCategory
    let diagnosticCategoryEvidence: String?
    let diagnosticCategoryConfidence: CommandDiagnosticConfidence
    let suggestedNextAction: CommandDiagnosticAction?

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
        let diagnosticCategoryMatch = Self.diagnosticCategoryMatch(
            failedCommandCount: failedCommandCount,
            latestFailedCommand: latestFailedCommand,
            recentFailureDiagnostic: recentFailureDiagnostic,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
        diagnosticCategory = diagnosticCategoryMatch.category
        diagnosticCategoryEvidence = diagnosticCategoryMatch.evidence
        diagnosticCategoryConfidence = diagnosticCategoryMatch.confidence
        diagnosticPriorityScore = Self.diagnosticPriorityScore(
            failedCommandCount: failedCommandCount,
            diagnosticSeverity: diagnosticSeverity,
            diagnosticCategory: diagnosticCategory,
            diagnosticCategoryConfidence: diagnosticCategoryConfidence,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
        diagnosticPriorityFactors = Self.diagnosticPriorityFactors(
            failedCommandCount: failedCommandCount,
            diagnosticSeverity: diagnosticSeverity,
            diagnosticCategory: diagnosticCategory,
            diagnosticCategoryConfidence: diagnosticCategoryConfidence,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
        suggestedNextInspection = Self.suggestedNextInspection(
            failedCommandCount: failedCommandCount,
            latestFailedCommand: latestFailedCommand,
            recentFailureDiagnostic: recentFailureDiagnostic,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic
        )
        suggestedNextAction = Self.suggestedNextAction(
            failedCommandCount: failedCommandCount,
            latestFailedCommand: latestFailedCommand,
            recentFailureDiagnostic: recentFailureDiagnostic,
            recentFailureFingerprint: recentFailureFingerprint,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic,
            diagnosticCategory: diagnosticCategory,
            diagnosticCategoryEvidence: diagnosticCategoryEvidence,
            diagnosticCategoryConfidence: diagnosticCategoryConfidence,
            diagnosticPriorityScore: diagnosticPriorityScore,
            diagnosticPriorityFactors: diagnosticPriorityFactors
        )
        suggestedNextCommand = suggestedNextAction?.command
    }

    var aiContextText: String? {
        var lines: [String] = []
        if failedCommandCount > 0 {
            lines.append("Failed commands: \(failedCommandCount)")
        }
        if diagnosticPriorityScore > 0 {
            lines.append("Diagnostic priority score: \(diagnosticPriorityScore)")
        }
        if !diagnosticPriorityFactors.isEmpty {
            let factors = diagnosticPriorityFactors.map(\.rawValue).joined(separator: "; ")
            lines.append("Diagnostic priority factors: \(factors)")
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
            lines.append("Repeated failure match: \(repeatedFailureDiagnostic.matchKind.rawValue)")
            lines.append(
                "Repeated failure window: \(Self.isoTimestamp(repeatedFailureDiagnostic.firstOccurredAt)) to \(Self.isoTimestamp(repeatedFailureDiagnostic.latestOccurredAt))"
            )
            lines.append("Repeated failure duration: \(repeatedFailureDiagnostic.durationMilliseconds) ms")
        }
        if diagnosticSeverity != .none {
            lines.append("Diagnostic severity: \(diagnosticSeverity.rawValue)")
        }
        if diagnosticCategory != .none {
            lines.append("Diagnostic category: \(diagnosticCategory.rawValue)")
        }
        if let diagnosticCategoryEvidence {
            lines.append("Diagnostic category evidence: \(diagnosticCategoryEvidence)")
        }
        if diagnosticCategoryConfidence != .none {
            lines.append("Diagnostic category confidence: \(diagnosticCategoryConfidence.rawValue)")
        }
        if let suggestedNextInspection {
            lines.append("Suggested next inspection: \(suggestedNextInspection)")
        }
        if let suggestedNextCommand {
            lines.append("Suggested next command: \(suggestedNextCommand)")
        }
        if let suggestedNextAction {
            lines.append("Suggested next action id: \(suggestedNextAction.id.rawValue)")
            lines.append("Suggested next action source category: \(suggestedNextAction.sourceCategory.rawValue)")
            lines.append("Suggested next action confidence: \(suggestedNextAction.confidence.rawValue)")
            lines.append("Suggested next action priority score: \(suggestedNextAction.priorityScore)")
            if !suggestedNextAction.priorityFactors.isEmpty {
                let priorityFactors = suggestedNextAction.priorityFactors.map(\.rawValue).joined(separator: "; ")
                lines.append("Suggested next action priority factors: \(priorityFactors)")
            }
            if !suggestedNextAction.evidenceAnchors.isEmpty {
                let evidenceAnchors = suggestedNextAction.evidenceAnchors.map(\.rawValue).joined(separator: "; ")
                lines.append("Suggested next action evidence anchors: \(evidenceAnchors)")
            }
            lines.append("Suggested next action scope: \(suggestedNextAction.actionScope.rawValue)")
            lines.append("Suggested next action title: \(suggestedNextAction.title)")
            lines.append("Suggested next action safety: \(suggestedNextAction.safety.rawValue)")
            lines.append("Suggested next action execution mode: \(suggestedNextAction.executionMode.rawValue)")
            lines.append("Suggested next action execution target: \(suggestedNextAction.executionTarget.rawValue)")
            lines.append("Suggested next action retry condition: \(suggestedNextAction.retryCondition.rawValue)")
            lines.append("Suggested next action preflight checks: \(suggestedNextAction.preflightChecks.joined(separator: "; "))")
            lines.append("Suggested next action automation guardrails: \(suggestedNextAction.automationGuardrails.joined(separator: "; "))")
            lines.append("Suggested next action user decision points: \(suggestedNextAction.userDecisionPoints.joined(separator: "; "))")
            lines.append("Suggested next action completion criteria: \(suggestedNextAction.completionCriteria.joined(separator: "; "))")
            lines.append("Suggested next action rationale: \(suggestedNextAction.rationale)")
            lines.append("Suggested next action expected signals: \(suggestedNextAction.expectedSignals.joined(separator: "; "))")
            lines.append("Suggested next action fallback steps: \(suggestedNextAction.fallbackNextSteps.joined(separator: "; "))")
            lines.append("Suggested next action requires confirmation: \(suggestedNextAction.requiresConfirmation)")
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
        var matchedRecords: [FailureDiagnosticRecord] = []
        for block in endedBlocks {
            guard isFailed(block),
                  let record = failureDiagnosticRecord(for: block, redactSensitiveData: redactSensitiveData),
                  record.fingerprint == latestRecord.fingerprint else {
                break
            }
            count += 1
            matchedBlocks.append(block)
            matchedRecords.append(record)
        }
        guard count >= Self.repeatedFailureThreshold,
              let latestMatchedBlock = matchedBlocks.first,
              let firstMatchedBlock = matchedBlocks.last else {
            return nil
        }
        let matchKind: RepeatedFailureMatchKind = matchedRecords.allSatisfy { $0.diagnostic == latestRecord.diagnostic }
            ? .exact
            : .normalized
        return RepeatedFailureDiagnostic(
            diagnostic: latestRecord.diagnostic,
            fingerprint: latestRecord.fingerprint,
            matchKind: matchKind,
            firstOccurredAt: occurrenceDate(for: firstMatchedBlock),
            latestOccurredAt: occurrenceDate(for: latestMatchedBlock),
            durationMilliseconds: failureDurationMilliseconds(
                firstOccurredAt: occurrenceDate(for: firstMatchedBlock),
                latestOccurredAt: occurrenceDate(for: latestMatchedBlock)
            ),
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

    nonisolated private static func diagnosticCategoryMatch(
        failedCommandCount: Int,
        latestFailedCommand: String?,
        recentFailureDiagnostic: String?,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    ) -> DiagnosticCategoryMatch {
        guard failedCommandCount > 0 else {
            return DiagnosticCategoryMatch(category: .none, evidence: nil, confidence: .none)
        }
        let command = latestFailedCommand?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let diagnostic = recentFailureDiagnostic?.lowercased() ?? ""
        if diagnostic.contains("address already in use")
            || diagnostic.contains("eaddrinuse")
            || diagnostic.contains("port already")
            || diagnostic.contains("listen tcp") {
            return DiagnosticCategoryMatch(
                category: .portConflict,
                evidence: recentFailureDiagnostic,
                confidence: .high
            )
        }
        if diagnostic.contains("permission denied") {
            return DiagnosticCategoryMatch(category: .permission, evidence: recentFailureDiagnostic, confidence: .high)
        }
        if diagnostic.contains("command not found") {
            return DiagnosticCategoryMatch(
                category: .missingCommand,
                evidence: recentFailureDiagnostic,
                confidence: .high
            )
        }
        if diagnostic.contains("no such file")
            || diagnostic.contains("not found")
            || diagnostic.contains("cannot find") {
            return DiagnosticCategoryMatch(category: .missingFile, evidence: recentFailureDiagnostic, confidence: .high)
        }
        if command.hasPrefix("git ")
            || command == "git" {
            return DiagnosticCategoryMatch(category: .git, evidence: latestFailedCommand, confidence: .medium)
        }
        if diagnostic.contains("fatal:") {
            return DiagnosticCategoryMatch(category: .git, evidence: recentFailureDiagnostic, confidence: .medium)
        }
        if repeatedFailureDiagnostic != nil {
            return DiagnosticCategoryMatch(
                category: .repeated,
                evidence: repeatedFailureDiagnostic?.diagnostic,
                confidence: .medium
            )
        }
        return DiagnosticCategoryMatch(
            category: .generic,
            evidence: recentFailureDiagnostic ?? latestFailedCommand,
            confidence: .low
        )
    }

    nonisolated private static func diagnosticPriorityScore(
        failedCommandCount: Int,
        diagnosticSeverity: CommandDiagnosticSeverity,
        diagnosticCategory: CommandDiagnosticCategory,
        diagnosticCategoryConfidence: CommandDiagnosticConfidence,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    ) -> Int {
        guard failedCommandCount > 0 else { return 0 }
        let severityScore: Int
        switch diagnosticSeverity {
        case .none:
            severityScore = 0
        case .failed:
            severityScore = 40
        case .repeated:
            severityScore = 70
        case .critical:
            severityScore = 90
        }

        let categoryScore: Int
        switch diagnosticCategory {
        case .none:
            categoryScore = 0
        case .portConflict, .permission:
            categoryScore = 8
        case .missingFile, .missingCommand, .git:
            categoryScore = 6
        case .repeated:
            categoryScore = 5
        case .generic:
            categoryScore = 2
        }

        let confidenceScore: Int
        switch diagnosticCategoryConfidence {
        case .none:
            confidenceScore = 0
        case .low:
            confidenceScore = 1
        case .medium:
            confidenceScore = 3
        case .high:
            confidenceScore = 6
        }

        let failedCountScore = min(10, failedCommandCount * 2)
        let repeatedCountScore = min(12, (repeatedFailureDiagnostic?.count ?? 0) * 2)
        return min(100, severityScore + categoryScore + confidenceScore + failedCountScore + repeatedCountScore)
    }

    nonisolated private static func diagnosticPriorityFactors(
        failedCommandCount: Int,
        diagnosticSeverity: CommandDiagnosticSeverity,
        diagnosticCategory: CommandDiagnosticCategory,
        diagnosticCategoryConfidence: CommandDiagnosticConfidence,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?
    ) -> [CommandDiagnosticPriorityFactor] {
        guard failedCommandCount > 0 else { return [] }
        var factors: [CommandDiagnosticPriorityFactor] = [.failedCommand]
        switch diagnosticSeverity {
        case .none:
            break
        case .failed:
            factors.append(.failedSeverity)
        case .repeated:
            factors.append(.repeatedSeverity)
        case .critical:
            factors.append(.criticalSeverity)
        }

        switch diagnosticCategory {
        case .none:
            break
        case .portConflict:
            factors.append(.portConflictCategory)
        case .permission:
            factors.append(.permissionCategory)
        case .missingFile:
            factors.append(.missingFileCategory)
        case .missingCommand:
            factors.append(.missingCommandCategory)
        case .git:
            factors.append(.gitCategory)
        case .repeated:
            factors.append(.repeatedCategory)
        case .generic:
            factors.append(.genericCategory)
        }

        switch diagnosticCategoryConfidence {
        case .none:
            break
        case .low:
            factors.append(.lowConfidenceCategory)
        case .medium:
            factors.append(.mediumConfidenceCategory)
        case .high:
            factors.append(.highConfidenceCategory)
        }

        if failedCommandCount > 1 {
            factors.append(.multipleFailures)
        }
        if repeatedFailureDiagnostic != nil {
            factors.append(.repeatedFailureCount)
        }
        return factors
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

    nonisolated private static func suggestedNextAction(
        failedCommandCount: Int,
        latestFailedCommand: String?,
        recentFailureDiagnostic: String?,
        recentFailureFingerprint: String?,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?,
        diagnosticCategory: CommandDiagnosticCategory,
        diagnosticCategoryEvidence: String?,
        diagnosticCategoryConfidence: CommandDiagnosticConfidence,
        diagnosticPriorityScore: Int,
        diagnosticPriorityFactors: [CommandDiagnosticPriorityFactor]
    ) -> CommandDiagnosticAction? {
        guard failedCommandCount > 0 else { return nil }
        let evidenceAnchors = Self.actionEvidenceAnchors(
            latestFailedCommand: latestFailedCommand,
            recentFailureDiagnostic: recentFailureDiagnostic,
            recentFailureFingerprint: recentFailureFingerprint,
            repeatedFailureDiagnostic: repeatedFailureDiagnostic,
            diagnosticCategoryEvidence: diagnosticCategoryEvidence
        )
        switch diagnosticCategory {
        case .none:
            return nil
        case .portConflict:
            return CommandDiagnosticAction(
                id: .listListeningPorts,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .localNetwork,
                title: "List listening TCP ports",
                rationale: "The latest failure looks like a local port conflict, so inspect listeners before rerunning.",
                command: "lsof -nP -iTCP -sTCP:LISTEN",
                expectedSignals: [
                    "Look for the conflicting local port.",
                    "Check the owning PID and process name before deciding whether to stop it."
                ],
                preflightChecks: [
                    "Confirm the failed command expected to bind a local TCP port.",
                    "Keep the follow-up inspection read-only until the owning process is identified."
                ],
                automationGuardrails: [
                    "Do not stop or kill the owning process automatically.",
                    "Do not assume local listeners explain failures from containers, VMs, or remote hosts."
                ],
                userDecisionPoints: [
                    "Decide whether the owning process can be stopped, restarted, or reconfigured.",
                    "Decide whether the failing service should move to another port instead."
                ],
                completionCriteria: [
                    "The conflicting port owner is identified and the next ownership decision is explicit.",
                    "The failed service can bind the intended port or has an intentional new port."
                ],
                fallbackNextSteps: [
                    "If the port is not listed locally, check whether the failure happened inside a container, VM, or remote host.",
                    "If the owner is unclear, inspect the process details before stopping anything."
                ],
                safety: .readOnly,
                executionTarget: .currentTerminalNetworkNamespace,
                retryCondition: .portConflictResolvedOrOwnerKnown
            )
        case .permission:
            return CommandDiagnosticAction(
                id: .inspectPermissions,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .permissionBoundary,
                title: "Inspect current permissions",
                rationale: "The latest failure mentions permission denied, so check the working directory and current user.",
                command: "pwd && id && ls -ld .",
                expectedSignals: [
                    "Confirm the command ran in the expected directory.",
                    "Compare the current user and directory permissions with the failed operation."
                ],
                preflightChecks: [
                    "Confirm the failure is from insufficient permissions rather than a missing path.",
                    "Check whether the command was intended to run locally, over SSH, or under sudo."
                ],
                automationGuardrails: [
                    "Do not run sudo, chmod, or chown automatically.",
                    "Do not broaden permissions without an explicit user decision."
                ],
                userDecisionPoints: [
                    "Decide whether elevated privileges are appropriate for this command.",
                    "Decide whether ownership or permissions should change, and on which exact path."
                ],
                completionCriteria: [
                    "The current user, target path, and required permission boundary are understood.",
                    "Any elevation or permission change is explicit before the failed command is retried."
                ],
                fallbackNextSteps: [
                    "If directory permissions look correct, inspect the target file, parent directory, or mounted volume permissions.",
                    "If the user is unexpected, check whether the shell, SSH profile, or sudo context changed."
                ],
                safety: .readOnly,
                executionTarget: .currentWorkingDirectory,
                retryCondition: .permissionsVerified
            )
        case .missingCommand:
            return CommandDiagnosticAction(
                id: .inspectPath,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .shellEnvironment,
                title: "Inspect PATH",
                rationale: "The latest failure says a command is missing, so check which directories the shell searches.",
                command: "echo \"$PATH\"",
                expectedSignals: [
                    "Confirm whether the expected tool directory is present in PATH.",
                    "If PATH looks correct, inspect whether the command is installed under a different name."
                ],
                preflightChecks: [
                    "Confirm the missing executable name from the failed command or diagnostic line.",
                    "Check whether the project requires an environment activation step before retrying."
                ],
                automationGuardrails: [
                    "Do not install packages automatically.",
                    "Do not edit shell startup files or PATH permanently without user approval."
                ],
                userDecisionPoints: [
                    "Decide whether to install the missing tool, activate an environment, or switch toolchains.",
                    "Decide whether the project should record the missing dependency in setup documentation."
                ],
                completionCriteria: [
                    "The intended executable resolves in the current shell or the missing dependency decision is recorded.",
                    "The environment activation or toolchain choice is clear before retrying."
                ],
                fallbackNextSteps: [
                    "If PATH contains the expected directory, run a read-only lookup such as command -v for the missing executable.",
                    "If the command exists in another shell, compare login shell startup files and project environment activation."
                ],
                safety: .readOnly,
                executionTarget: .currentShellEnvironment,
                retryCondition: .commandAvailableOnPath
            )
        case .missingFile:
            return CommandDiagnosticAction(
                id: .inspectDirectory,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .workingDirectory,
                title: "Inspect current directory",
                rationale: "The latest failure references a missing file, so confirm the current directory and visible files.",
                command: "pwd && ls -la",
                expectedSignals: [
                    "Confirm the command ran in the directory that should contain the file.",
                    "Check whether the missing file is absent, renamed, hidden, or has unexpected casing."
                ],
                preflightChecks: [
                    "Confirm the missing path is expected to exist before rerunning.",
                    "Check whether the command depends on generated files or a project setup step."
                ],
                automationGuardrails: [
                    "Do not create placeholder files automatically.",
                    "Do not delete or move nearby files while diagnosing a missing path."
                ],
                userDecisionPoints: [
                    "Decide whether the missing path should be restored, generated, renamed, or reconfigured.",
                    "Decide whether the command should run from a different working directory."
                ],
                completionCriteria: [
                    "The expected path exists in the intended directory or the command/config now points elsewhere intentionally.",
                    "Generated-file prerequisites are identified before retrying the failed command."
                ],
                fallbackNextSteps: [
                    "If the directory is correct, search the project tree for the expected filename or config equivalent.",
                    "If the file is generated, rerun the generation or install step before retrying the failed command."
                ],
                safety: .readOnly,
                executionTarget: .currentWorkingDirectory,
                retryCondition: .fileOrDirectoryVerified
            )
        case .git:
            return CommandDiagnosticAction(
                id: .inspectGitState,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .gitRepository,
                title: "Inspect Git state",
                rationale: "The latest failed command or diagnostic is Git-related, so inspect branch and dirty state first.",
                command: "git status --short --branch",
                expectedSignals: [
                    "Check the current branch and upstream relation.",
                    "Look for dirty, conflicted, staged, or untracked files before retrying Git commands."
                ],
                preflightChecks: [
                    "Confirm the failed command was run inside the intended repository.",
                    "Check whether local changes, conflicts, or upstream drift could change the retry result."
                ],
                automationGuardrails: [
                    "Do not run reset, checkout, merge, rebase, stash, or clean automatically.",
                    "Do not discard or rewrite local changes without explicit user approval."
                ],
                userDecisionPoints: [
                    "Decide how to handle dirty, conflicted, staged, or untracked files.",
                    "Decide whether the failed Git command should be retried, replaced, or postponed."
                ],
                completionCriteria: [
                    "The branch, upstream relation, and working tree risk are understood.",
                    "Any retry, stash, merge, rebase, or cleanup decision is explicit."
                ],
                fallbackNextSteps: [
                    "If status is clean, inspect the failed Git command output for remote, auth, or repository path clues.",
                    "If conflicts or dirty files are present, resolve or stash intentionally before rerunning."
                ],
                safety: .readOnly,
                executionTarget: .currentGitRepository,
                retryCondition: .gitStateReviewed
            )
        case .repeated:
            return CommandDiagnosticAction(
                id: .inspectRepeatContext,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .repeatedFailureContext,
                title: "Inspect repeat context",
                rationale: "The latest failures repeat, so capture location and Git state before another retry.",
                command: "pwd && git status --short --branch 2>/dev/null || true",
                expectedSignals: [
                    "Confirm whether repeated failures are happening in the expected working directory.",
                    "If this is a Git project, compare branch and dirty state before another rerun."
                ],
                preflightChecks: [
                    "Confirm whether anything meaningful changed since the last failed attempt.",
                    "Prefer inspecting the first failure output if the command and context are unchanged."
                ],
                automationGuardrails: [
                    "Do not rerun the same failing command in a loop.",
                    "Do not mutate project state until the repeated failure cause is understood."
                ],
                userDecisionPoints: [
                    "Decide whether any context changed enough to justify another retry.",
                    "Decide whether to inspect logs, configuration, or the first failure output before continuing."
                ],
                completionCriteria: [
                    "A material context change is captured or the first failure output has been inspected.",
                    "The next attempt has a different hypothesis than the repeated failing attempts."
                ],
                fallbackNextSteps: [
                    "If context is unchanged, inspect the first repeated failure output instead of rerunning immediately.",
                    "If context changed between attempts, capture the changed directory, branch, or environment before comparing results."
                ],
                safety: .readOnly,
                executionTarget: .currentTerminalSession,
                retryCondition: .contextChangedOrFirstFailureInspected
            )
        case .generic:
            return CommandDiagnosticAction(
                id: .inspectLocalContext,
                sourceCategory: diagnosticCategory,
                confidence: diagnosticCategoryConfidence,
                priorityScore: diagnosticPriorityScore,
                priorityFactors: diagnosticPriorityFactors,
                evidenceAnchors: evidenceAnchors,
                actionScope: .terminalSession,
                title: "Inspect local context",
                rationale: "The failure is not specific enough yet, so capture location and Git state as a safe first step.",
                command: "pwd && git status --short --branch 2>/dev/null || true",
                expectedSignals: [
                    "Confirm the working directory before deeper inspection.",
                    "If available, use Git state to correlate the failure with recent local changes."
                ],
                preflightChecks: [
                    "Confirm the failure has enough output to guide a targeted next step.",
                    "Keep the first inspection read-only until the failing dependency is clearer."
                ],
                automationGuardrails: [
                    "Do not guess a destructive fix from a generic failure.",
                    "Do not change environment, dependencies, or files until the failure is categorized more specifically."
                ],
                userDecisionPoints: [
                    "Decide which subsystem or dependency should be inspected next.",
                    "Decide whether there is enough evidence before attempting any mutating fix."
                ],
                completionCriteria: [
                    "The failure is recategorized or enough context is captured for a targeted next check.",
                    "No mutating fix is attempted while the failure remains generic."
                ],
                fallbackNextSteps: [
                    "If local context is inconclusive, inspect the last output lines and the command exit code together.",
                    "If the command depends on a service or file, run a read-only health or existence check next."
                ],
                safety: .readOnly,
                executionTarget: .currentTerminalSession,
                retryCondition: .localContextCaptured
            )
        }
    }

    nonisolated private static func actionEvidenceAnchors(
        latestFailedCommand: String?,
        recentFailureDiagnostic: String?,
        recentFailureFingerprint: String?,
        repeatedFailureDiagnostic: RepeatedFailureDiagnostic?,
        diagnosticCategoryEvidence: String?
    ) -> [CommandDiagnosticEvidenceAnchor] {
        var anchors: [CommandDiagnosticEvidenceAnchor] = []
        if latestFailedCommand != nil {
            anchors.append(.latestFailedCommand)
        }
        if recentFailureDiagnostic != nil {
            anchors.append(.recentFailureDiagnostic)
        }
        if recentFailureFingerprint != nil {
            anchors.append(.recentFailureFingerprint)
        }
        if repeatedFailureDiagnostic != nil {
            anchors.append(.repeatedFailureDiagnostic)
        }
        if diagnosticCategoryEvidence != nil {
            anchors.append(.diagnosticCategoryEvidence)
        }
        return anchors
    }

    nonisolated private static func occurrenceDate(for block: TerminalCommandBlock) -> Date {
        block.endedAt ?? block.startedAt
    }

    nonisolated private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated private static func failureDurationMilliseconds(
        firstOccurredAt: Date,
        latestOccurredAt: Date
    ) -> Int {
        max(0, Int(latestOccurredAt.timeIntervalSince(firstOccurredAt) * 1000))
    }

    nonisolated private static let repeatedFailureThreshold = 3
}

struct RepeatedFailureDiagnostic: Equatable {
    let diagnostic: String
    let fingerprint: String
    let matchKind: RepeatedFailureMatchKind
    let firstOccurredAt: Date
    let latestOccurredAt: Date
    let durationMilliseconds: Int
    let count: Int
}

enum RepeatedFailureMatchKind: String, Codable, Equatable {
    case exact
    case normalized
}

enum CommandDiagnosticSeverity: String, Codable, Equatable {
    case none
    case failed
    case repeated
    case critical
}

enum CommandDiagnosticCategory: String, Codable, Equatable {
    case none
    case portConflict = "port_conflict"
    case permission
    case missingFile = "missing_file"
    case missingCommand = "missing_command"
    case git
    case repeated
    case generic
}

enum CommandDiagnosticConfidence: String, Codable, Equatable {
    case none
    case low
    case medium
    case high
}

enum CommandDiagnosticPriorityFactor: String, Codable, Equatable {
    case failedCommand = "failed_command"
    case failedSeverity = "failed_severity"
    case repeatedSeverity = "repeated_severity"
    case criticalSeverity = "critical_severity"
    case portConflictCategory = "port_conflict_category"
    case permissionCategory = "permission_category"
    case missingFileCategory = "missing_file_category"
    case missingCommandCategory = "missing_command_category"
    case gitCategory = "git_category"
    case repeatedCategory = "repeated_category"
    case genericCategory = "generic_category"
    case lowConfidenceCategory = "low_confidence_category"
    case mediumConfidenceCategory = "medium_confidence_category"
    case highConfidenceCategory = "high_confidence_category"
    case multipleFailures = "multiple_failures"
    case repeatedFailureCount = "repeated_failure_count"
}

struct CommandDiagnosticAction: Codable, Equatable {
    let id: CommandDiagnosticActionID
    let sourceCategory: CommandDiagnosticCategory
    let confidence: CommandDiagnosticConfidence
    let priorityScore: Int
    let priorityFactors: [CommandDiagnosticPriorityFactor]
    let evidenceAnchors: [CommandDiagnosticEvidenceAnchor]
    let actionScope: CommandDiagnosticActionScope
    let title: String
    let rationale: String
    let command: String
    let expectedSignals: [String]
    let preflightChecks: [String]
    let automationGuardrails: [String]
    let userDecisionPoints: [String]
    let completionCriteria: [String]
    let fallbackNextSteps: [String]
    let safety: CommandDiagnosticActionSafety
    let executionMode: CommandDiagnosticActionExecutionMode
    let executionTarget: CommandDiagnosticActionExecutionTarget
    let retryCondition: CommandDiagnosticActionRetryCondition
    let requiresConfirmation: Bool

    nonisolated init(
        id: CommandDiagnosticActionID,
        sourceCategory: CommandDiagnosticCategory,
        confidence: CommandDiagnosticConfidence,
        priorityScore: Int,
        priorityFactors: [CommandDiagnosticPriorityFactor],
        evidenceAnchors: [CommandDiagnosticEvidenceAnchor],
        actionScope: CommandDiagnosticActionScope,
        title: String,
        rationale: String,
        command: String,
        expectedSignals: [String],
        preflightChecks: [String],
        automationGuardrails: [String],
        userDecisionPoints: [String],
        completionCriteria: [String],
        fallbackNextSteps: [String],
        safety: CommandDiagnosticActionSafety,
        executionMode: CommandDiagnosticActionExecutionMode = .stageOnly,
        executionTarget: CommandDiagnosticActionExecutionTarget,
        retryCondition: CommandDiagnosticActionRetryCondition,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.sourceCategory = sourceCategory
        self.confidence = confidence
        self.priorityScore = priorityScore
        self.priorityFactors = priorityFactors
        self.evidenceAnchors = evidenceAnchors
        self.actionScope = actionScope
        self.title = title
        self.rationale = rationale
        self.command = command
        self.expectedSignals = expectedSignals
        self.preflightChecks = preflightChecks
        self.automationGuardrails = automationGuardrails
        self.userDecisionPoints = userDecisionPoints
        self.completionCriteria = completionCriteria
        self.fallbackNextSteps = fallbackNextSteps
        self.safety = safety
        self.executionMode = executionMode
        self.executionTarget = executionTarget
        self.retryCondition = retryCondition
        self.requiresConfirmation = requiresConfirmation
    }
}

enum CommandDiagnosticActionID: String, Codable, Equatable {
    case listListeningPorts = "list_listening_ports"
    case inspectPermissions = "inspect_permissions"
    case inspectPath = "inspect_path"
    case inspectDirectory = "inspect_directory"
    case inspectGitState = "inspect_git_state"
    case inspectRepeatContext = "inspect_repeat_context"
    case inspectLocalContext = "inspect_local_context"
}

enum CommandDiagnosticActionSafety: String, Codable, Equatable {
    case readOnly = "read_only"
}

enum CommandDiagnosticActionExecutionMode: String, Codable, Equatable {
    case stageOnly = "stage_only"
}

enum CommandDiagnosticEvidenceAnchor: String, Codable, Equatable {
    case latestFailedCommand = "latest_failed_command"
    case recentFailureDiagnostic = "recent_failure_diagnostic"
    case recentFailureFingerprint = "recent_failure_fingerprint"
    case repeatedFailureDiagnostic = "repeated_failure_diagnostic"
    case diagnosticCategoryEvidence = "diagnostic_category_evidence"
}

enum CommandDiagnosticActionScope: String, Codable, Equatable {
    case terminalSession = "terminal_session"
    case localNetwork = "local_network"
    case permissionBoundary = "permission_boundary"
    case shellEnvironment = "shell_environment"
    case workingDirectory = "working_directory"
    case gitRepository = "git_repository"
    case repeatedFailureContext = "repeated_failure_context"
}

enum CommandDiagnosticActionExecutionTarget: String, Codable, Equatable {
    case currentTerminalSession = "current_terminal_session"
    case currentTerminalNetworkNamespace = "current_terminal_network_namespace"
    case currentWorkingDirectory = "current_working_directory"
    case currentShellEnvironment = "current_shell_environment"
    case currentGitRepository = "current_git_repository"
}

enum CommandDiagnosticActionRetryCondition: String, Codable, Equatable {
    case portConflictResolvedOrOwnerKnown = "port_conflict_resolved_or_owner_known"
    case permissionsVerified = "permissions_verified"
    case commandAvailableOnPath = "command_available_on_path"
    case fileOrDirectoryVerified = "file_or_directory_verified"
    case gitStateReviewed = "git_state_reviewed"
    case contextChangedOrFirstFailureInspected = "context_changed_or_first_failure_inspected"
    case localContextCaptured = "local_context_captured"
}

private struct FailureDiagnosticRecord: Equatable {
    let diagnostic: String
    let fingerprint: String
}

private struct DiagnosticCategoryMatch: Equatable {
    let category: CommandDiagnosticCategory
    let evidence: String?
    let confidence: CommandDiagnosticConfidence
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
