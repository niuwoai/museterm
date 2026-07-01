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
            return duration >= failureMinimumDuration || block.outputSummary?.hasErrorSignal == true
        }
        if block.commandLifecycleState == .succeeded, notifyLongCompletion {
            return duration >= longThreshold
        }
        return false
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
        let key = "\(session.id.uuidString):\(notificationKey(for: event))"
        let now = Date()
        if let last = lastDeliveryDates[key],
           now.timeIntervalSince(last) < preferences.notificationCooldownSeconds {
            return
        }
        lastDeliveryDates[key] = now

        let content = UNMutableNotificationContent()
        let payload = notificationPayload(for: event, session: session, includeCommand: preferences.includeCommandInNotifications)
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

    private var isAuthorizedForSystemNotifications: Bool {
        canRequestAuthorization == false && authorizationStatusSystemImage == "checkmark.circle.fill"
    }

    private func notificationPayload(
        for event: TerminalAttentionEventKind,
        session: TerminalSession,
        includeCommand: Bool
    ) -> (title: String, body: String) {
        switch event {
        case .bell:
            return (
                L10n.string("notification.bell.title"),
                L10n.format("notification.bell.body", session.tabTitle)
            )
        case .processExited(let exitCode):
            if let exitCode {
                return (
                    L10n.string("notification.process_exited.title"),
                    L10n.format("notification.process_exited.body_with_exit", session.tabTitle, exitCode)
                )
            }
            return (
                L10n.string("notification.process_exited.title"),
                L10n.format("notification.process_exited.body", session.tabTitle)
            )
        case .commandFinished(let block):
            return commandNotificationPayload(block, session: session, includeCommand: includeCommand)
        }
    }

    private func commandNotificationPayload(
        _ block: TerminalCommandBlock,
        session: TerminalSession,
        includeCommand: Bool
    ) -> (title: String, body: String) {
        let command = sanitizedCommand(block.command)
        let duration = formattedDuration(block.durationMilliseconds)
        switch block.commandLifecycleState {
        case .failed:
            let title = L10n.string("notification.command_failed.title")
            if includeCommand {
                return (title, L10n.format("notification.command_failed.body_with_command", session.tabTitle, block.exitCode ?? -1, duration, command))
            }
            return (title, L10n.format("notification.command_failed.body", session.tabTitle, block.exitCode ?? -1, duration))
        case .succeeded:
            let title = L10n.string("notification.command_completed.title")
            if includeCommand {
                return (title, L10n.format("notification.command_completed.body_with_command", session.tabTitle, duration, command))
            }
            return (title, L10n.format("notification.command_completed.body", session.tabTitle, duration))
        default:
            return (
                L10n.string("notification.command_finished.title"),
                L10n.format("notification.command_finished.body", session.tabTitle)
            )
        }
    }

    private func notificationKey(for event: TerminalAttentionEventKind) -> String {
        switch event {
        case .bell:
            return "bell"
        case .processExited:
            return "process-exited"
        case .commandFinished(let block):
            return "command-\(block.commandLifecycleState.rawValue)"
        }
    }

    private func sanitizedCommand(_ command: String) -> String {
        let redacted = RunbookSensitiveRedactor.redact(command)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard redacted.count > 96 else { return redacted }
        return String(redacted.prefix(93)) + "..."
    }

    private func formattedDuration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return L10n.string("notification.duration.unknown") }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    private func applyAuthorizationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
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
