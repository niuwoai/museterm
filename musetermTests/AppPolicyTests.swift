import AppKit
import XCTest
@testable import museterm

final class AppPolicyTests: XCTestCase {
    func testDefaultPreferencesUseSeaSaltSkin() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.skin, TerminalVisualSkin.seaSalt)
        XCTAssertTrue(preferences.glassEnabled)
        XCTAssertTrue(preferences.showsTabList)
        XCTAssertEqual(preferences.fontSize, 14)
        XCTAssertEqual(preferences.lineStartShortcut, "command+left")
        XCTAssertEqual(preferences.lineEndShortcut, "command+right")
    }

    func testLineNavigationShortcutsPersist() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.lineStartShortcut = "control+char:a"
        preferences.lineEndShortcut = "end"

        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.lineStartShortcut, "control+char:a")
        XCTAssertEqual(reloaded.lineEndShortcut, "end")
    }

    func testTerminalKeyBindingMatchesSemanticArrowShortcut() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        ))

        XCTAssertTrue(TerminalKeyBinding.defaultLineStart.matches(event))
        XCTAssertFalse(TerminalKeyBinding.defaultLineEnd.matches(event))
        XCTAssertEqual(TerminalKeyBinding.defaultLineStart.displayName, "⌘←")
        XCTAssertEqual(
            TerminalLineNavigationAction.resolve(
                event: event,
                lineStartShortcut: TerminalKeyBinding.defaultLineStart.storageValue,
                lineEndShortcut: TerminalKeyBinding.defaultLineEnd.storageValue
            ),
            .lineStart
        )
        XCTAssertEqual(TerminalLineNavigationAction.lineStart.bytes, [0x01])
        XCTAssertEqual(TerminalLineNavigationAction.lineEnd.bytes, [0x05])
    }

    func testTerminalSkinsProvideAnsi16Colors() {
        for skin in TerminalVisualSkin.allCases {
            XCTAssertEqual(skin.ansiSwiftTermColors.count, 16)
            XCTAssertEqual(skin.ansiColors.count, 16)
        }
    }

    func testAppIconChoicesKeepSinglePenguinEntry() {
        let rawValues = AppIconChoice.allCases.map(\.rawValue)

        XCTAssertTrue(rawValues.contains(AppIconChoice.defaultTerminal.rawValue))
        XCTAssertFalse(rawValues.contains("penguin"))
    }

    func testNotificationPolicyUsesTabBadgeForInactiveTabWhileAppIsActive() {
        let delivery = TerminalNotificationPolicy.delivery(for: notificationPolicyInput(
            event: .bell,
            appIsActive: true,
            tabIsSelected: false
        ))

        if case .tabBadge = delivery {
        } else {
            XCTFail("Expected inactive foreground tabs to receive a badge, got \(delivery)")
        }
    }

    func testNotificationPolicyStaysSilentForActiveTabWhileAppIsActive() {
        let delivery = TerminalNotificationPolicy.delivery(for: notificationPolicyInput(
            event: .bell,
            appIsActive: true,
            tabIsSelected: true
        ))

        if case .none = delivery {
        } else {
            XCTFail("Expected active foreground tabs to stay silent, got \(delivery)")
        }
    }

    func testNotificationPolicyDoesNotNotifyShortFailuresWithoutErrorSignal() {
        let block = commandBlock(
            exitCode: 1,
            duration: 1,
            outputSummary: nil
        )
        let delivery = TerminalNotificationPolicy.delivery(for: notificationPolicyInput(
            event: .commandFinished(block),
            appIsActive: false,
            tabIsSelected: false
        ))

        if case .none = delivery {
        } else {
            XCTFail("Expected short failures without error signals to stay silent, got \(delivery)")
        }
    }

    func testNotificationPolicyNotifiesObviousFailuresEvenWhenShort() {
        let block = commandBlock(
            exitCode: 1,
            duration: 1,
            outputSummary: TerminalOutputSummary(
                insightKinds: [.error],
                errorLine: "fatal: port already in use",
                warningLine: nil,
                url: nil,
                filePath: nil,
                commitHash: nil,
                stackTraceLine: nil
            )
        )
        let delivery = TerminalNotificationPolicy.delivery(for: notificationPolicyInput(
            event: .commandFinished(block),
            appIsActive: false,
            tabIsSelected: false
        ))

        if case .systemNotification(let markTabBadge) = delivery {
            XCTAssertTrue(markTabBadge)
        } else {
            XCTFail("Expected obvious background failures to produce a system notification, got \(delivery)")
        }
    }

    func testNotificationPayloadOmitsCommandWhenPrivacyDisabled() {
        let block = commandBlock(
            command: "make test --filter LoginTests",
            exitCode: 1,
            duration: 12,
            outputSummary: nil
        )
        let payload = TerminalNotificationPayloadBuilder.payload(
            for: .commandFinished(block),
            sessionTitle: "API",
            includeCommand: false
        )

        XCTAssertEqual(payload.cooldownKey, "command-failed")
        XCTAssertFalse(payload.body.contains("make test"))
        XCTAssertFalse(payload.body.contains("LoginTests"))
    }

    func testNotificationPayloadIncludesSanitizedCommandWhenAllowed() {
        let block = commandBlock(
            command: "  make    test --filter LoginTests  ",
            exitCode: 0,
            duration: 42,
            outputSummary: nil
        )
        let payload = TerminalNotificationPayloadBuilder.payload(
            for: .commandFinished(block),
            sessionTitle: "API",
            includeCommand: true
        )

        XCTAssertEqual(payload.cooldownKey, "command-succeeded")
        XCTAssertTrue(payload.body.contains("make test --filter LoginTests"))
    }

    func testNotificationPayloadUsesStableCooldownKeys() {
        let failedBlock = commandBlock(exitCode: 1, duration: 12, outputSummary: nil)
        let succeededBlock = commandBlock(exitCode: 0, duration: 42, outputSummary: nil)

        XCTAssertEqual(
            TerminalNotificationPayloadBuilder.payload(for: .bell, sessionTitle: "API", includeCommand: false).cooldownKey,
            "bell"
        )
        XCTAssertEqual(
            TerminalNotificationPayloadBuilder.payload(for: .processExited(9), sessionTitle: "API", includeCommand: false).cooldownKey,
            "process-exited"
        )
        XCTAssertEqual(
            TerminalNotificationPayloadBuilder.payload(for: .commandFinished(failedBlock), sessionTitle: "API", includeCommand: false).cooldownKey,
            "command-failed"
        )
        XCTAssertEqual(
            TerminalNotificationPayloadBuilder.payload(for: .commandFinished(succeededBlock), sessionTitle: "API", includeCommand: false).cooldownKey,
            "command-succeeded"
        )
    }

    func testToolInputMapsNamedControlKeys() {
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "enter", rawBytes: nil), [0x0D])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "ctrl-c", rawBytes: nil), [0x03])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "tab", rawBytes: nil), [0x09])
        XCTAssertEqual(TerminalToolInput.bytes(text: "abc", key: nil, rawBytes: nil), Array("abc".utf8))
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: nil, rawBytes: [1, 2, 3]), [1, 2, 3])
    }

    @MainActor
    func testToolResponseEncodesRequestMetadata() throws {
        let response = TerminalToolResponse(
            version: "test",
            id: "request-1",
            ok: true,
            snapshotSequence: 42,
            action: "send_key",
            tabID: "tab-1",
            message: "sent",
            error: nil
        )

        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["app"] as? String, "MuseTerm")
        XCTAssertEqual(object["version"] as? String, "test")
        XCTAssertEqual(object["id"] as? String, "request-1")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(object["action"] as? String, "send_key")
        XCTAssertEqual(object["tabID"] as? String, "tab-1")
    }

    private func notificationPolicyInput(
        event: TerminalAttentionEventKind,
        appIsActive: Bool,
        tabIsSelected: Bool
    ) -> TerminalNotificationPolicyInput {
        TerminalNotificationPolicyInput(
            event: event,
            appIsActive: appIsActive,
            tabIsSelected: tabIsSelected,
            notificationsEnabled: true,
            showInactiveTabBadges: true,
            notifyBells: true,
            notifyCommandFailures: true,
            notifyLongCommandCompletion: true,
            notifyProcessExits: false,
            longCommandThresholdSeconds: 30,
            failureMinimumDurationSeconds: 5
        )
    }

    private func commandBlock(
        command: String = "make test",
        exitCode: Int32,
        duration: TimeInterval,
        outputSummary: TerminalOutputSummary?
    ) -> TerminalCommandBlock {
        let startedAt = Date()
        return TerminalCommandBlock(
            id: UUID(),
            command: command,
            workingDirectory: "/tmp/project",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            exitCode: exitCode,
            outputTail: outputSummary?.primaryDiagnosticLine ?? "",
            outputCharacterCount: outputSummary?.primaryDiagnosticLine?.count ?? 0,
            outputSummary: outputSummary,
            isInteractive: false,
            commandStartSource: .userInput,
            completionSource: .shellIntegration
        )
    }
}
