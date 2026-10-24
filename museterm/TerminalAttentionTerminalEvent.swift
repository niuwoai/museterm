import Foundation

extension TerminalReminderPolicy {
    init(preferences: TerminalPreferences) {
        self.init(bells: preferences.notifyTerminalBell, commandFailures: preferences.notifyCommandFailures,
            longCommandCompletion: preferences.notifyLongCommandCompletion, processExits: preferences.notifyProcessExits,
            longCommandSeconds: preferences.longCommandNotificationThresholdSeconds,
            failureMinimumSeconds: preferences.failureNotificationMinimumDurationSeconds)
    }
}

extension TerminalAttentionTerminalContext {
    init(event: TerminalAttentionEventKind, processRunID: UUID) {
        switch event {
        case .bell:
            self.init(kind: .bell, eventID: processRunID, commandID: nil, exitCode: nil, failed: false)
        case .commandFinished(let block):
            self.init(kind: .commandFinished, eventID: block.id, commandID: block.id,
                exitCode: block.exitCode, failed: block.commandLifecycleState == .failed)
        case .processExited(let code):
            self.init(kind: .processExited, eventID: processRunID, commandID: nil, exitCode: code, failed: code != nil && code != 0)
        }
    }
}

extension TerminalAttentionStore {
    /// Eligibility determines inbox content; system notification permission only controls delivery.
    func recordTerminal(_ event: TerminalAttentionEventKind, session: TerminalSession,
                        input: TerminalNotificationPolicyInput) -> TerminalAttentionItem? {
        guard !session.runtimeOwnsTerminalAttention, session.attentionStore === self, TerminalNotificationPolicy.isEligible(input),
              let item = recordTerminal(TerminalAttentionTerminalContext(event: event,
                processRunID: session.processRunID), tabID: session.id) else { return nil }
        if input.appIsActive && input.tabIsSelected {
            // Do not acknowledge an unrelated Agent question in the same terminal.
            try? markRead(id: item.id, version: item.version)
        }
        return item
    }
}
