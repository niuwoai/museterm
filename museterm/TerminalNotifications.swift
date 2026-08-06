import AppKit
import Combine
import Foundation
import UserNotifications

enum TerminalAttentionEventKind {
    case bell
    case commandFinished(TerminalCommandBlock)
    case processExited(Int32?)
}

protocol TerminalAttentionReporting: AnyObject {
    func terminalSession(_ session: TerminalSession, didProduceAttentionEvent event: TerminalAttentionEventKind)
}

enum TerminalNotificationDelivery: Equatable {
    case none
    case tabBadge
    case systemNotification(markTabBadge: Bool)
}

struct TerminalNotificationPolicyInput {
    var event: TerminalAttentionEventKind
    var appIsActive: Bool
    var tabIsSelected: Bool
    var notificationsEnabled: Bool
    var showInactiveTabBadges: Bool
    var notifyBells: Bool
    var notifyCommandFailures: Bool
    var notifyLongCommandCompletion: Bool
    var notifyProcessExits: Bool
    var longCommandThresholdSeconds: Double
    var failureMinimumDurationSeconds: Double
}

enum TerminalNotificationPolicy {
    static func delivery(for input: TerminalNotificationPolicyInput) -> TerminalNotificationDelivery {
        guard input.notificationsEnabled, isEligible(input) else { return .none }

        if input.appIsActive {
            guard !input.tabIsSelected else { return .none }
            return input.showInactiveTabBadges ? .tabBadge : .none
        }

        return .systemNotification(markTabBadge: input.showInactiveTabBadges && !input.tabIsSelected)
    }

    private static func isEligible(_ input: TerminalNotificationPolicyInput) -> Bool {
        switch input.event {
        case .bell:
            return input.notifyBells
        case .processExited:
            return input.notifyProcessExits
        case .commandFinished(let block):
            return commandShouldNotify(
                block,
                notifyFailures: input.notifyCommandFailures,
                notifyLongCompletion: input.notifyLongCommandCompletion,
                longThreshold: input.longCommandThresholdSeconds,
                failureMinimumDuration: input.failureMinimumDurationSeconds
            )
        }
    }

    private static func commandShouldNotify(
        _ block: TerminalCommandBlock,
        notifyFailures: Bool,
        notifyLongCompletion: Bool,
        longThreshold: Double,
        failureMinimumDuration: Double
    ) -> Bool {
        guard block.endedAt != nil else { return false }
        let duration = Double(block.durationMilliseconds ?? 0) / 1_000
        if block.commandLifecycleState == .failed, notifyFailures {
            guard !isLowInformationShellCommand(block.command) else { return false }
            return duration >= failureMinimumDuration || block.outputSummary?.hasErrorSignal == true
        }
        if block.commandLifecycleState == .succeeded, notifyLongCompletion {
            return duration >= longThreshold
        }
        return false
    }

    private static func isLowInformationShellCommand(_ command: String) -> Bool {
        let words = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return true }

        let wrappers: Set<String> = ["builtin", "command"]
        let commandIndex = words.indices.first { !wrappers.contains(words[$0]) } ?? words.startIndex
        let commandName = URL(fileURLWithPath: words[commandIndex]).lastPathComponent
        let lowInformationCommands: Set<String> = [
            "alias", "bg", "cd", "clear", "dirs", "disown", "export", "false",
            "fg", "history", "jobs", "popd", "pushd", "pwd", "true", "unalias", "unset"
        ]
        return lowInformationCommands.contains(commandName)
    }
}

struct TerminalNotificationPayload: Equatable {
    var title: String
    var body: String
    var cooldownKey: String
}

enum TerminalNotificationPayloadBuilder {
    static func payload(
        for event: TerminalAttentionEventKind,
        sessionTitle: String,
        includeCommand: Bool
    ) -> TerminalNotificationPayload {
        switch event {
        case .bell:
            return TerminalNotificationPayload(
                title: L10n.string("notification.bell.title"),
                body: L10n.format("notification.bell.body", sessionTitle),
                cooldownKey: cooldownKey(for: event)
            )
        case .processExited(let exitCode):
            let body: String
            if let exitCode {
                body = L10n.format("notification.process_exited.body_with_exit", sessionTitle, exitCode)
            } else {
                body = L10n.format("notification.process_exited.body", sessionTitle)
            }
            return TerminalNotificationPayload(
                title: L10n.string("notification.process_exited.title"),
                body: body,
                cooldownKey: cooldownKey(for: event)
            )
        case .commandFinished(let block):
            return commandPayload(
                block,
                sessionTitle: sessionTitle,
                includeCommand: includeCommand
            )
        }
    }

    private static func commandPayload(
        _ block: TerminalCommandBlock,
        sessionTitle: String,
        includeCommand: Bool
    ) -> TerminalNotificationPayload {
        let command = sanitizedCommand(block.command)
        let duration = formattedDuration(block.durationMilliseconds)
        let key = cooldownKey(for: .commandFinished(block))
        switch block.commandLifecycleState {
        case .failed:
            let title = L10n.string("notification.command_failed.title")
            let body = includeCommand
                ? L10n.format("notification.command_failed.body_with_command", sessionTitle, duration, command)
                : L10n.format("notification.command_failed.body", sessionTitle, duration)
            return TerminalNotificationPayload(title: title, body: body, cooldownKey: key)
        case .succeeded:
            let title = L10n.string("notification.command_completed.title")
            let body = includeCommand
                ? L10n.format("notification.command_completed.body_with_command", sessionTitle, duration, command)
                : L10n.format("notification.command_completed.body", sessionTitle, duration)
            return TerminalNotificationPayload(title: title, body: body, cooldownKey: key)
        default:
            return TerminalNotificationPayload(
                title: L10n.string("notification.command_finished.title"),
                body: L10n.format("notification.command_finished.body", sessionTitle),
                cooldownKey: key
            )
        }
    }

    private static func cooldownKey(for event: TerminalAttentionEventKind) -> String {
        switch event {
        case .bell:
            return "bell"
        case .processExited:
            return "process-exited"
        case .commandFinished(let block):
            return "command-\(block.commandLifecycleState.rawValue)"
        }
    }

    private static func sanitizedCommand(_ command: String) -> String {
        let redacted = RunbookSensitiveRedactor.redact(command)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard redacted.count > 96 else { return redacted }
        return String(redacted.prefix(93)) + "..."
    }

    private static func formattedDuration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return L10n.string("notification.duration.unknown") }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }
}

final class TerminalNotificationCoordinator: NSObject, ObservableObject, TerminalAttentionReporting {
    static let shared = TerminalNotificationCoordinator()

    @Published private(set) var authorizationStatusLabel = L10n.string("notifications.permission.unknown")
    @Published private(set) var authorizationStatusSystemImage = "questionmark.circle"
    @Published private(set) var canRequestAuthorization = true

    private weak var workspace: TerminalWorkspace?
    private weak var preferences: TerminalPreferences?
    private var cancellables: Set<AnyCancellable> = []
    private var lastDeliveryDates: [String: Date] = [:]

    private override init() {
        super.init()
        refreshAuthorizationStatus()
    }

    func attach(workspace: TerminalWorkspace, preferences: TerminalPreferences) {
        self.workspace = workspace
        self.preferences = preferences
        workspace.attentionReporter = self

        cancellables.removeAll()
        workspace.$selectedID
            .sink { [weak workspace] selectedID in
                guard let selectedID,
                      let tab = workspace?.tabs.first(where: { $0.id == selectedID }) else { return }
                tab.clearUnreadAttention()
            }
            .store(in: &cancellables)

        refreshAuthorizationStatus()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAuthorizationStatus()
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.applyAuthorizationStatus(settings.authorizationStatus)
            }
        }
    }

    func terminalSession(_ session: TerminalSession, didProduceAttentionEvent event: TerminalAttentionEventKind) {
        guard let workspace, let preferences else { return }
        let input = TerminalNotificationPolicyInput(
            event: event,
            appIsActive: NSApplication.shared.isActive,
            tabIsSelected: workspace.selectedID == session.id,
            notificationsEnabled: preferences.notificationsEnabled,
            showInactiveTabBadges: preferences.showInactiveTabNotificationBadges,
            notifyBells: preferences.notifyTerminalBell,
            notifyCommandFailures: preferences.notifyCommandFailures,
            notifyLongCommandCompletion: preferences.notifyLongCommandCompletion,
            notifyProcessExits: preferences.notifyProcessExits,
            longCommandThresholdSeconds: preferences.longCommandNotificationThresholdSeconds,
            failureMinimumDurationSeconds: preferences.failureNotificationMinimumDurationSeconds
        )

        switch TerminalNotificationPolicy.delivery(for: input) {
        case .none:
            return
        case .tabBadge:
            session.markUnreadAttention()
        case .systemNotification(let markTabBadge):
            if markTabBadge {
                session.markUnreadAttention()
            }
            deliverSystemNotification(for: event, session: session, preferences: preferences)
        }
    }

    private func deliverSystemNotification(
        for event: TerminalAttentionEventKind,
        session: TerminalSession,
        preferences: TerminalPreferences
    ) {
        guard isAuthorizedForSystemNotifications else { return }
        let payload = TerminalNotificationPayloadBuilder.payload(
            for: event,
            sessionTitle: session.tabTitle,
            includeCommand: preferences.includeCommandInNotifications
        )
        let key = "\(session.id.uuidString):\(payload.cooldownKey)"
        let now = Date()
        if let last = lastDeliveryDates[key],
           now.timeIntervalSince(last) < preferences.notificationCooldownSeconds {
            return
        }
        lastDeliveryDates[key] = now
        pruneExpiredDeliveryDates(now: now, cooldownSeconds: preferences.notificationCooldownSeconds)

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = ["tabID": session.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "museterm-\(key)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // 冷却窗口外的时间戳不再拦截任何通知，长时间运行多标签时定期清掉，避免字典无界增长。
    private func pruneExpiredDeliveryDates(now: Date, cooldownSeconds: Double) {
        guard lastDeliveryDates.count > 64 else { return }
        lastDeliveryDates = lastDeliveryDates.filter {
            now.timeIntervalSince($0.value) < cooldownSeconds
        }
    }

    private var isAuthorizedForSystemNotifications: Bool {
        canRequestAuthorization == false && authorizationStatusSystemImage == "checkmark.circle.fill"
    }

    private func applyAuthorizationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional:
            authorizationStatusLabel = L10n.string("notifications.permission.allowed")
            authorizationStatusSystemImage = "checkmark.circle.fill"
            canRequestAuthorization = false
        case .denied:
            authorizationStatusLabel = L10n.string("notifications.permission.denied")
            authorizationStatusSystemImage = "xmark.circle.fill"
            canRequestAuthorization = false
        case .notDetermined:
            authorizationStatusLabel = L10n.string("notifications.permission.not_determined")
            authorizationStatusSystemImage = "exclamationmark.circle"
            canRequestAuthorization = true
        @unknown default:
            authorizationStatusLabel = L10n.string("notifications.permission.unknown")
            authorizationStatusSystemImage = "questionmark.circle"
            canRequestAuthorization = true
        }
    }
}

private extension TerminalOutputSummary {
    var hasErrorSignal: Bool {
        insightKinds.contains(.error)
            || insightKinds.contains(.stackTrace)
            || errorLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || stackTraceLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
