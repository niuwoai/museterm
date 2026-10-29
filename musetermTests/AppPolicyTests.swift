import AppKit
import XCTest
@testable import museterm

final class AppPolicyTests: XCTestCase {
    func testIMECommitForwardsPlainReturnAfterCompositionEnds() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertTrue(
                TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                    keyCode: keyCode,
                    modifiers: [],
                    hadMarkedText: true,
                    hasMarkedText: false
                )
            )
        }
    }

    func testIMECommitDoesNotDuplicateUnrelatedKeysOrIncompleteComposition() {
        XCTAssertFalse(
            TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                keyCode: 36,
                modifiers: [],
                hadMarkedText: false,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                keyCode: 36,
                modifiers: [],
                hadMarkedText: true,
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                keyCode: 0,
                modifiers: [],
                hadMarkedText: true,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            TerminalIMECommitPolicy.shouldForwardReturnAfterCommit(
                keyCode: 36,
                modifiers: [.shift],
                hadMarkedText: true,
                hasMarkedText: false
            )
        )
    }

    func testRepeatedCommandPalettePresentationKeepsPaletteVisible() {
        var presentation = CommandPalettePresentationState()

        presentation.present()
        presentation.present()

        XCTAssertTrue(presentation.isPresented)
        presentation.dismiss()
        XCTAssertFalse(presentation.isPresented)
    }

    func testCommandPaletteConsumesSupportedUnmodifiedKeys() throws {
        let testCases: [(keyCode: UInt16, expected: CommandPaletteKeyboardAction)] = [
            (126, .selectPrevious),
            (125, .selectNext),
            (36, .execute),
            (76, .execute),
            (53, .dismiss)
        ]

        for testCase in testCases {
            let event = try XCTUnwrap(keyDownEvent(keyCode: testCase.keyCode))
            XCTAssertEqual(CommandPaletteKeyboardAction.resolve(event: event), testCase.expected)
        }
    }

    func testCommandPaletteLeavesTextAndModifiedKeysToSearchField() throws {
        let letterEvent = try XCTUnwrap(keyDownEvent(keyCode: 0, characters: "a"))
        let modifiedArrow = try XCTUnwrap(keyDownEvent(keyCode: 125, modifiers: [.shift]))

        XCTAssertNil(CommandPaletteKeyboardAction.resolve(event: letterEvent))
        XCTAssertNil(CommandPaletteKeyboardAction.resolve(event: modifiedArrow))
    }

    func testCommandPaletteDoesNotScrollWhileSelectionStaysInVisibleBand() {
        // 高亮落在可视带 [top+margin, top+visibleCount-1-margin] = [8, 11] 内 → 列表不动。
        let plan = CommandPaletteScrollPolicy.plan(
            topIndex: 5,
            selectedIndex: 9,
            visibleCount: 10,
            itemCount: 50,
            margin: 3
        )

        XCTAssertEqual(plan, .none)
    }

    func testCommandPaletteScrollsUpToKeepMarginAboveWhenHittingTopEdge() {
        // 高亮升到可视带上沿之上 → 滚动到高亮上方保留 margin 行：newTop = 6 - 3 = 3。
        let plan = CommandPaletteScrollPolicy.plan(
            topIndex: 5,
            selectedIndex: 6,
            visibleCount: 10,
            itemCount: 50,
            margin: 3
        )

        XCTAssertEqual(plan, .scrollTopTo(index: 3))
    }

    func testCommandPaletteScrollsDownToKeepMarginBelowWhenHittingBottomEdge() {
        // 高亮降到可视带下沿之下 → newTop = 13 - (10-1) + 3 = 7，使高亮下方仍留 margin 行。
        let plan = CommandPaletteScrollPolicy.plan(
            topIndex: 5,
            selectedIndex: 13,
            visibleCount: 10,
            itemCount: 50,
            margin: 3
        )

        XCTAssertEqual(plan, .scrollTopTo(index: 7))
    }

    func testCommandPaletteDoesNotScrollWhenAllRowsFitViewport() {
        let plan = CommandPaletteScrollPolicy.plan(
            topIndex: 0,
            selectedIndex: 4,
            visibleCount: 5,
            itemCount: 5,
            margin: 3
        )

        XCTAssertEqual(plan, .none)
    }

    func testCommandPaletteClampsScrollAtListEnds() {
        // 顶部已到 0，向上移动不再滚动。
        let atTop = CommandPaletteScrollPolicy.plan(
            topIndex: 0,
            selectedIndex: 1,
            visibleCount: 10,
            itemCount: 50,
            margin: 3
        )
        // 底部已到 maxTop（40），向下移动不再滚动。
        let atBottom = CommandPaletteScrollPolicy.plan(
            topIndex: 40,
            selectedIndex: 49,
            visibleCount: 10,
            itemCount: 50,
            margin: 3
        )

        XCTAssertEqual(atTop, .none)
        XCTAssertEqual(atBottom, .none)
    }

    func testDefaultPreferencesUseSeaSaltSkin() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.skin, TerminalVisualSkin.seaSalt)
        XCTAssertTrue(preferences.glassEnabled)
        XCTAssertEqual(preferences.windowOpacity, 0.72)
        XCTAssertEqual(preferences.terminalOpacity, 0.86)
        XCTAssertTrue(preferences.showsTabList)
        XCTAssertEqual(preferences.sidebarExpandedWidth, 220)
        XCTAssertEqual(preferences.fontSize, 14)
        XCTAssertEqual(preferences.scrollbackLines, 3_000)
        XCTAssertEqual(preferences.appShortcut(for: .newTab), "command+char:t")
        XCTAssertEqual(preferences.appShortcut(for: .closeTab), "command+char:w")
        XCTAssertEqual(preferences.appShortcut(for: .commandPalette), "shift+command+char:p")
        XCTAssertEqual(preferences.appShortcut(for: .searchCommands), "command+char:f")
        XCTAssertEqual(preferences.lineStartShortcut, "command+left")
        XCTAssertEqual(preferences.lineEndShortcut, "command+right")
    }

    func testTransparencyPreferencesPersistIndependently() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.glassEnabled = false
        preferences.glassOpacity = 0.35
        preferences.windowOpacity = 0.48
        preferences.terminalOpacity = 0.22

        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.glassEnabled)
        XCTAssertEqual(reloaded.glassOpacity, 0.35)
        XCTAssertEqual(reloaded.windowOpacity, 0.48)
        XCTAssertEqual(reloaded.terminalOpacity, 0.22)
    }

    private func keyDownEvent(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    func testPrimaryShortcutsPersistAndResolveCommandPalette() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.setAppShortcut("option+command+char:k", for: .commandPalette)

        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.appShortcut(for: .commandPalette), "option+command+char:k")

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ))
        XCTAssertEqual(
            TerminalAppShortcutAction.resolve(
                event: event,
                shortcut: { reloaded.appShortcut(for: $0) }
            ),
            .commandPalette
        )
    }

    func testShortcutAssignmentClearsConflictingBindings() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.setAppShortcut("command+char:t", for: .commandPalette)

        XCTAssertEqual(preferences.appShortcut(for: .commandPalette), "command+char:t")
        XCTAssertEqual(preferences.appShortcut(for: .newTab), "")

        preferences.setLineNavigationShortcut("command+char:t", for: .lineStart)
        XCTAssertEqual(preferences.lineStartShortcut, "command+char:t")
        XCTAssertEqual(preferences.appShortcut(for: .commandPalette), "")

        preferences.restoreDefaultAppShortcuts()
        XCTAssertEqual(preferences.appShortcut(for: .newTab), "command+char:t")
        XCTAssertEqual(preferences.appShortcut(for: .commandPalette), "shift+command+char:p")
        XCTAssertEqual(preferences.lineStartShortcut, "")
    }

    func testScrollbackLinesPersistAndClampToMaximum() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.scrollbackLines = 12_000

        var reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.scrollbackLines, 12_000)

        preferences.scrollbackLines = 99_000
        reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.scrollbackLines, 20_000)
        XCTAssertEqual(reloaded.scrollbackLines, 20_000)
    }

    func testSidebarExpandedWidthPersistsAndClamps() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.sidebarExpandedWidth = 320

        var reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.sidebarExpandedWidth, 320)

        preferences.sidebarExpandedWidth = 120
        reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.sidebarExpandedWidth, 220)
        XCTAssertEqual(reloaded.sidebarExpandedWidth, 220)

        preferences.sidebarExpandedWidth = 900
        reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.sidebarExpandedWidth, 420)
        XCTAssertEqual(reloaded.sidebarExpandedWidth, 420)
    }

    func testSidebarSectionOrderAndVisibilityPersist() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.sidebarSectionOrder, SidebarSectionKind.defaultOrder)
        XCTAssertTrue(preferences.hiddenSidebarSections.isEmpty)
        XCTAssertEqual(preferences.visibleSidebarSections, SidebarSectionKind.defaultOrder)

        preferences.setSidebarSection(.shortcuts, visible: false)
        preferences.moveSidebarSection(.sshHosts, direction: -1)
        SidebarSectionOrder.applyDrop(of: .fileTransfer, onto: .quickPaths, in: preferences)

        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(
            reloaded.sidebarSectionOrder,
            [.fileTransfer, .quickPaths, .learnedCommands, .shortcuts, .sshHosts, .profiles]
        )
        XCTAssertEqual(reloaded.hiddenSidebarSections, [.shortcuts])
        XCTAssertFalse(reloaded.visibleSidebarSections.contains(.shortcuts))

        reloaded.setSidebarSection(.shortcuts, visible: true)
        XCTAssertTrue(reloaded.isSidebarSectionVisible(.shortcuts))
        XCTAssertEqual(reloaded.visibleSidebarSections.first, .fileTransfer)
    }

    func testSidebarSectionOrderDropsUnknownValuesAndKeepsMissingSections() {
        let normalized = SidebarSectionKind.normalizedOrder(["sshHosts", "nope", "sshHosts", "shortcuts"])
        XCTAssertEqual(
            normalized,
            [.sshHosts, .shortcuts, .quickPaths, .learnedCommands, .fileTransfer, .profiles]
        )
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
        let paletteBinding = try XCTUnwrap(TerminalKeyBinding(storageValue: "shift+command+char:p"))
        XCTAssertEqual(paletteBinding.displayName, "⇧⌘P")
        XCTAssertFalse(paletteBinding.isReservedApplicationShortcut)
        XCTAssertTrue(
            try XCTUnwrap(TerminalKeyBinding(storageValue: "command+char:1"))
                .isReservedApplicationShortcut
        )
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

    func testNotificationPolicyDoesNotNotifyNavigationCommandFailures() {
        let block = commandBlock(
            command: "cd /missing-directory",
            exitCode: 1,
            duration: 12,
            outputSummary: TerminalOutputSummary(
                insightKinds: [.error],
                errorLine: "cd: no such file or directory",
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

        XCTAssertEqual(delivery, .none)
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
        XCTAssertFalse(payload.body.contains("exit 1"))
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
