//
//  musetermTests.swift
//  musetermTests
//
//  Created by rocky on 2026/6/30.
//

import Foundation
import XCTest
@testable import museterm

final class musetermTests: XCTestCase {

    func testDefaultPreferencesUseSeaSaltSkin() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.skin, TerminalVisualSkin.seaSalt)
        XCTAssertEqual(preferences.colorPalette, TerminalColorPalette.apple)
        XCTAssertTrue(preferences.glassEnabled)
        XCTAssertTrue(preferences.showsTabList)
        XCTAssertEqual(preferences.fontSize, 14)
    }

    func testTerminalPalettesProvideAnsi16Colors() {
        for palette in TerminalColorPalette.allCases {
            XCTAssertEqual(palette.swiftTermColors.count, 16)
            XCTAssertEqual(palette.nsColors.count, 16)
        }
    }

    func testToolInputMapsNamedControlKeys() {
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "enter", rawBytes: nil), [0x0D])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "ctrl-c", rawBytes: nil), [0x03])
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: "tab", rawBytes: nil), [0x09])
        XCTAssertEqual(TerminalToolInput.bytes(text: "abc", key: nil, rawBytes: nil), Array("abc".utf8))
        XCTAssertEqual(TerminalToolInput.bytes(text: nil, key: nil, rawBytes: [1, 2, 3]), [1, 2, 3])
    }

    func testCliInstallerScriptExposesMCPAndTerminalCommands() {
        let script = MuseTermCLIInstaller.script

        XCTAssertTrue(script.contains("museterm tabs"))
        XCTAssertTrue(script.contains("museterm screen"))
        XCTAssertTrue(script.contains("museterm history"))
        XCTAssertTrue(script.contains("museterm input"))
        XCTAssertTrue(script.contains("museterm key"))
        XCTAssertTrue(script.contains("commands_payload"))
        XCTAssertTrue(script.contains("\"schemaVersion\" => state[\"schemaVersion\"]"))
        XCTAssertTrue(script.contains("commands_payload(state, tab, chars)"))
        XCTAssertTrue(script.contains("commands_payload(state, tab, args[\"chars\"])"))
        XCTAssertTrue(script.contains("\"diagnostics\" => tab.fetch(\"commandDiagnostics\", {})"))
        XCTAssertTrue(script.contains("\"tools/call\""))
        XCTAssertTrue(script.contains("read_screen"))
        XCTAssertTrue(script.contains("send_key"))
    }

    @MainActor
    func testToolTabSnapshotEncodesCommandDiagnostics() throws {
        let diagnostic = "ERROR database is locked"
        let diagnostics = CommandBlockDiagnostics(
            blocks: [
                commandBlock(command: "make test", startedAt: 100, endedAt: 101, exitCode: 1, errorLine: diagnostic),
                commandBlock(command: "make test", startedAt: 110, endedAt: 111, exitCode: 1, errorLine: diagnostic),
                commandBlock(command: "make test", startedAt: 120, endedAt: 121, exitCode: 1, errorLine: diagnostic)
            ]
        )
        let snapshot = TerminalToolTabSnapshot(
            id: "tab-1",
            index: 1,
            title: "project",
            subtitle: nil,
            currentDirectory: "/tmp/project",
            isSelected: true,
            state: "running",
            columns: 80,
            rows: 24,
            screen: "",
            history: "",
            commandDiagnostics: TerminalToolCommandDiagnosticsSnapshot(diagnostics: diagnostics),
            commandBlocks: [],
            updatedAt: Date(timeIntervalSince1970: 130)
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedDiagnostics = try XCTUnwrap(object["commandDiagnostics"] as? [String: Any])
        let repeatedFailure = try XCTUnwrap(encodedDiagnostics["repeatedFailureDiagnostic"] as? [String: Any])
        let suggestedNextAction = try XCTUnwrap(encodedDiagnostics["suggestedNextAction"] as? [String: Any])
        let state = TerminalToolState(
            app: "MuseTerm",
            version: "test",
            updatedAt: Date(timeIntervalSince1970: 130),
            selectedTabID: "tab-1",
            tabs: [snapshot]
        )
        let stateData = try JSONEncoder().encode(state)
        let stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])

        XCTAssertEqual(stateObject["schemaVersion"] as? Int, 1)
        XCTAssertEqual(encodedDiagnostics["schemaVersion"] as? Int, 1)
        XCTAssertEqual(encodedDiagnostics["failedCommandCount"] as? Int, 3)
        XCTAssertEqual(encodedDiagnostics["diagnosticSeverity"] as? String, CommandDiagnosticSeverity.repeated.rawValue)
        XCTAssertEqual(encodedDiagnostics["diagnosticCategory"] as? String, CommandDiagnosticCategory.repeated.rawValue)
        XCTAssertEqual(encodedDiagnostics["diagnosticCategoryEvidence"] as? String, diagnostic)
        XCTAssertEqual(
            encodedDiagnostics["diagnosticCategoryConfidence"] as? String,
            CommandDiagnosticConfidence.medium.rawValue
        )
        XCTAssertEqual(encodedDiagnostics["latestFailedCommand"] as? String, "make test")
        XCTAssertEqual(encodedDiagnostics["recentFailureDiagnostic"] as? String, diagnostic)
        XCTAssertEqual(encodedDiagnostics["recentFailureFingerprint"] as? String, "error database is locked")
        XCTAssertEqual(
            encodedDiagnostics["suggestedNextInspection"] as? String,
            "Inspect the repeated failure output before rerunning: \(diagnostic)"
        )
        XCTAssertEqual(
            encodedDiagnostics["suggestedNextCommand"] as? String,
            "pwd && git status --short --branch 2>/dev/null || true"
        )
        XCTAssertEqual(suggestedNextAction["id"] as? String, CommandDiagnosticActionID.inspectRepeatContext.rawValue)
        XCTAssertEqual(suggestedNextAction["sourceCategory"] as? String, CommandDiagnosticCategory.repeated.rawValue)
        XCTAssertEqual(suggestedNextAction["confidence"] as? String, CommandDiagnosticConfidence.medium.rawValue)
        XCTAssertEqual(suggestedNextAction["title"] as? String, "Inspect repeat context")
        XCTAssertEqual(
            suggestedNextAction["rationale"] as? String,
            "The latest failures repeat, so capture location and Git state before another retry."
        )
        XCTAssertEqual(
            suggestedNextAction["command"] as? String,
            "pwd && git status --short --branch 2>/dev/null || true"
        )
        let expectedSignals = try XCTUnwrap(suggestedNextAction["expectedSignals"] as? [String])
        XCTAssertEqual(expectedSignals.count, 2)
        XCTAssertTrue(expectedSignals[0].contains("expected working directory"))
        let fallbackNextSteps = try XCTUnwrap(suggestedNextAction["fallbackNextSteps"] as? [String])
        XCTAssertEqual(fallbackNextSteps.count, 2)
        XCTAssertTrue(fallbackNextSteps[0].contains("first repeated failure output"))
        XCTAssertEqual(suggestedNextAction["safety"] as? String, CommandDiagnosticActionSafety.readOnly.rawValue)
        XCTAssertEqual(suggestedNextAction["requiresConfirmation"] as? Bool, true)
        XCTAssertEqual(repeatedFailure["diagnostic"] as? String, diagnostic)
        XCTAssertEqual(repeatedFailure["fingerprint"] as? String, "error database is locked")
        XCTAssertEqual(repeatedFailure["matchKind"] as? String, RepeatedFailureMatchKind.exact.rawValue)
        XCTAssertNotNil(repeatedFailure["firstOccurredAt"])
        XCTAssertNotNil(repeatedFailure["latestOccurredAt"])
        XCTAssertEqual(repeatedFailure["durationMilliseconds"] as? Int, 20_000)
        XCTAssertEqual(repeatedFailure["count"] as? Int, 3)
    }

    func testWorkspaceCreatesAndSelectsTabs() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertNotEqual(firstTab.id, secondTab.id)
        XCTAssertEqual(workspace.selectedID, secondTab.id)
    }

    func testShortcutNewTabDeduplicatesDoubleDispatch() {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)

        workspace.newTabFromShortcut(eventTimestamp: 100)
        workspace.newTabFromShortcut(eventTimestamp: 100)

        XCTAssertEqual(workspace.tabs.count, 2)

        workspace.newTabFromShortcut(eventTimestamp: 101)
        XCTAssertEqual(workspace.tabs.count, 3)
    }

    func testWorkspaceCyclesTabsWithKeyboardActions() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let firstTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)

        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)

        workspace.selectNextTab()
        XCTAssertEqual(workspace.selectedID, firstTab.id)

        workspace.selectPreviousTab()
        XCTAssertEqual(workspace.selectedID, thirdTab.id)

        workspace.selectTab(at: 1)
        XCTAssertEqual(workspace.selectedID, secondTab.id)

        workspace.selectTab(at: 99)
        XCTAssertEqual(workspace.selectedID, secondTab.id)
    }

    func testTabTitleHidesLocalUserHostTitle() {
        let tab = TerminalSession(sequence: 1)
        tab.title = "\(NSUserName())@\(ProcessInfo.processInfo.hostName):~"
        tab.currentDirectory = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertNotEqual(tab.tabTitle, tab.title)
        XCTAssertEqual(tab.tabTitle, FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
        XCTAssertNil(tab.tabSubtitle)
    }

    func testTabTitleKeepsRemoteUserHostTitle() {
        let tab = TerminalSession(sequence: 1)
        tab.title = "deploy@production-box:/srv/app"
        tab.currentDirectory = "/srv/app"

        XCTAssertEqual(tab.tabTitle, "deploy@production-box")
        XCTAssertEqual(tab.tabSubtitle, "app")
    }

    func testTerminalShortcutRecorderProtectsEchoOffInput() throws {
        let started = Date(timeIntervalSince1970: 100)
        let recorder = TerminalShortcutRecorder(startedAt: started)

        recorder.record(data: Array("ls\n".utf8), echoEnabled: true, now: started.addingTimeInterval(0.2))
        recorder.record(data: Array("secret\n".utf8), echoEnabled: false, now: started.addingTimeInterval(0.5))

        let shortcut = try XCTUnwrap(recorder.finish(title: "Deploy", finishedAt: started.addingTimeInterval(1)))
        XCTAssertEqual(shortcut.events.count, 2)
        XCTAssertFalse(shortcut.events[0].requiresEchoOff)
        XCTAssertTrue(shortcut.events[1].requiresEchoOff)
        XCTAssertTrue(shortcut.hasProtectedInput)
        XCTAssertEqual(shortcut.events[1].bytes, [])
        XCTAssertEqual(shortcut.events[1].transientProtectedBytes, Array("secret\n".utf8))
    }

    func testSSHConfigRendersPerHopIdentityAndProxyJump() {
        let firstJump = SSHJumpHost(
            name: "bastion",
            host: "jump1.example.com",
            user: "ops",
            port: 2222,
            identityFiles: ["~/.ssh/jump1"]
        )
        let secondJump = SSHJumpHost(
            host: "jump2.example.com",
            user: "root",
            port: 22,
            identityFiles: ["~/.ssh/jump2"]
        )
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            identityFiles: ["~/.ssh/prod"],
            jumpHosts: [firstJump, secondJump],
            extraOptions: ["ServerAliveInterval 30"]
        )

        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("Host museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("IdentityFile "))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-2"))
        XCTAssertTrue(config.contains("HostName prod.internal"))
        XCTAssertTrue(config.contains("ServerAliveInterval 30"))
    }

    func testOutputInsightAnalyzerDetectsCommonSignals() {
        let output = """
        ERROR failed to compile Sources/App.swift:42
        warning: deprecated option
        See https://example.com/build/123
        commit abc1234 fixed the issue
        at Module.run (/srv/app/index.js:10:2)
        """

        let kinds = Set(TerminalOutputInsightAnalyzer.insights(in: output).map(\.kind))

        XCTAssertTrue(kinds.contains(.error))
        XCTAssertTrue(kinds.contains(.warning))
        XCTAssertTrue(kinds.contains(.url))
        XCTAssertTrue(kinds.contains(.filePath))
        XCTAssertTrue(kinds.contains(.commitHash))
        XCTAssertTrue(kinds.contains(.stackTrace))
    }

    func testOutputInsightAnalyzerFormatsJSONSummary() throws {
        let output = #"{"z":2,"a":{"ok":true}}"#

        let formatted = try XCTUnwrap(TerminalOutputInsightAnalyzer.formattedJSON(in: output))
        XCTAssertTrue(formatted.contains(#""a" : {"#))
        XCTAssertTrue(formatted.contains(#""ok" : true"#))

        let summary = TerminalOutputInsightAnalyzer.summary(in: output)
        XCTAssertTrue(summary.contains("formattedJSON:"))
        XCTAssertTrue(summary.contains("json:"))
    }

    func testOutputInsightAnalyzerBuildsCompactOutputSummary() throws {
        let output = """
        ERROR failed to compile Sources/App.swift:42
        See https://example.com/build/123
        commit abc1234 fixed the issue
        """

        let summary = try XCTUnwrap(TerminalOutputInsightAnalyzer.outputSummary(in: output))

        XCTAssertEqual(summary.errorLine, "ERROR failed to compile Sources/App.swift:42")
        XCTAssertEqual(summary.url, "https://example.com/build/123")
        XCTAssertEqual(summary.filePath, "Sources/App.swift:42")
        XCTAssertEqual(summary.commitHash, "abc1234")
        XCTAssertTrue(summary.insightKinds.contains(.error))
        XCTAssertTrue(summary.searchableText.contains("abc1234"))
        XCTAssertTrue(summary.aiContextText.contains("Output error:"))
        XCTAssertEqual(summary.primaryDiagnosticLine, "ERROR failed to compile Sources/App.swift:42")
    }

    func testOutputSummaryPrimaryDiagnosticFallsBackToWarning() {
        let summary = TerminalOutputSummary(
            insightKinds: [.warning, .url],
            errorLine: nil,
            warningLine: "warning: deprecated option",
            url: "https://example.com/warnings",
            filePath: nil,
            commitHash: nil,
            stackTraceLine: nil
        )

        XCTAssertEqual(summary.primaryDiagnosticLine, "warning: deprecated option")
    }

    func testShellIntegrationParserAcceptsSplitCompletionMarker() {
        let parser = TerminalShellIntegrationParser()

        let firstChunk = Array("\u{1B}]777;MuseTerm;".utf8)
        let secondChunk = Array("end=127\u{7}".utf8)

        XCTAssertEqual(parser.accept(firstChunk[...]), [])
        XCTAssertEqual(parser.accept(secondChunk[...]), [.commandFinished(127)])
    }

    func testShellIntegrationParserAcceptsCommandStartMarker() {
        let parser = TerminalShellIntegrationParser()
        let marker = "\u{1B}]777;MuseTerm;start=73776966742074657374\u{7}"

        XCTAssertEqual(parser.accept(Array(marker.utf8)[...]), [.commandStarted("swift test")])
    }

    func testCommandBlockStoresCompletionSource() throws {
        let tab = TerminalSession(sequence: 1)

        tab.observeProcessInput(
            data: Array("swift test\r".utf8),
            echoEnabled: true,
            historySnapshot: "$ swift test\n"
        )
        XCTAssertEqual(tab.commandBlocks.count, 1)
        XCTAssertNil(tab.commandBlocks[0].completionSource)

        tab.finishActiveCommand(
            exitCode: 1,
            completionSource: .shellIntegration,
            historySnapshot: "$ swift test\nTests failed\n"
        )

        let block = try XCTUnwrap(tab.commandBlocks.first)
        XCTAssertEqual(block.exitCode, 1)
        XCTAssertEqual(block.completionSource, .shellIntegration)
        XCTAssertTrue(block.searchableText.contains("shellIntegration"))
        XCTAssertTrue(block.aiContextText.contains("Completion source: shellIntegration"))
    }

    func testShellIntegratedStartUpgradesUserInputCommandBlock() throws {
        let tab = TerminalSession(sequence: 1)

        tab.observeProcessInput(
            data: Array("swift   test\r".utf8),
            echoEnabled: true,
            historySnapshot: "$ swift   test\n"
        )

        tab.startShellIntegratedCommand(
            command: "swift test",
            historySnapshot: "$ swift   test\n"
        )

        let block = try XCTUnwrap(tab.commandBlocks.first)
        XCTAssertEqual(tab.commandBlocks.count, 1)
        XCTAssertEqual(block.command, "swift test")
        XCTAssertEqual(block.commandStartSource, .shellIntegration)
        XCTAssertTrue(block.searchableText.contains("shellIntegration"))
        XCTAssertTrue(block.aiContextText.contains("Command source: shellIntegration"))
    }

    func testCommandBlockStoresOutputSummary() throws {
        let tab = TerminalSession(sequence: 1)

        tab.observeProcessInput(
            data: Array("swift build\r".utf8),
            echoEnabled: true,
            historySnapshot: "$ swift build\n"
        )
        tab.observeProcessOutput(
            historySnapshot: "$ swift build\nERROR failed Sources/App.swift:42\nhttps://example.com/build\n"
        )

        let block = try XCTUnwrap(tab.commandBlocks.first)
        let summary = try XCTUnwrap(block.outputSummary)
        XCTAssertEqual(summary.errorLine, "ERROR failed Sources/App.swift:42")
        XCTAssertEqual(summary.filePath, "Sources/App.swift:42")
        XCTAssertEqual(summary.url, "https://example.com/build")
        XCTAssertTrue(block.searchableText.contains("Sources/App.swift:42"))
        XCTAssertTrue(block.aiContextText.contains("Output summary:"))
    }

    func testRunbookMarkdownIncludesRedactedOutputSummary() {
        let tab = TerminalSession(sequence: 1)
        let secret = "sk-123456789012345678901234"
        let block = TerminalCommandBlock(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            command: "swift build",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: 1,
            outputTail: "",
            outputCharacterCount: 128,
            outputSummary: TerminalOutputSummary(
                insightKinds: [.error, .url],
                errorLine: "ERROR token=\(secret)",
                warningLine: nil,
                url: "https://example.com/build/123",
                filePath: "Sources/App.swift:42",
                commitHash: "abc1234",
                stackTraceLine: nil
            ),
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .shellIntegration
        )

        let markdown = RunbookMarkdownExporter.markdown(
            tab: tab,
            blocks: [block],
            query: "",
            failuresOnly: false,
            note: "",
            redactSensitiveData: true,
            includeReplayScript: false,
            parameterizeReplayScript: false,
            confirmReplaySteps: true,
            variableOverrides: RunbookReplayVariableOverrides(homePath: "", workingDirectory: "")
        )

        XCTAssertTrue(markdown.contains(L10n.string("runbook.output_summary")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.summary_error")))
        XCTAssertTrue(markdown.contains("[REDACTED]"))
        XCTAssertTrue(markdown.contains("https://example.com/build/123"))
        XCTAssertTrue(markdown.contains("Sources/App.swift:42"))
        XCTAssertFalse(markdown.contains(secret))
    }

    func testRunbookMarkdownIncludesRepeatedFailureDiagnostics() {
        let tab = TerminalSession(sequence: 1)
        let secret = "sk-abcdefghijklmnopqrstuvwxyz"
        let repeated = "ERROR token=\(secret)"
        let blocks = [
            commandBlock(command: "make test", startedAt: 100, endedAt: 101, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 110, endedAt: 111, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 120, endedAt: 121, exitCode: 1, errorLine: repeated)
        ]

        let markdown = RunbookMarkdownExporter.markdown(
            tab: tab,
            blocks: blocks,
            query: "",
            failuresOnly: true,
            note: "",
            redactSensitiveData: true,
            includeReplayScript: false,
            parameterizeReplayScript: false,
            confirmReplaySteps: true,
            variableOverrides: RunbookReplayVariableOverrides(homePath: "", workingDirectory: "")
        )

        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failure")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.failed_commands")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_severity")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category_evidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category_confidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.failure_fingerprint")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failed_command")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_inspection")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_command")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_id")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_source_category")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_confidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_safety")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_expected_signals")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_fallback_steps")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_confirmation")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_rationale")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.repeated_failure")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.repeated_failure_match")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.repeated_failure_window")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.repeated_failure_duration")))
        XCTAssertTrue(markdown.contains("3"))
        XCTAssertTrue(markdown.contains(CommandDiagnosticSeverity.repeated.rawValue))
        XCTAssertTrue(markdown.contains(CommandDiagnosticCategory.repeated.rawValue))
        XCTAssertTrue(markdown.contains(CommandDiagnosticConfidence.medium.rawValue))
        XCTAssertTrue(markdown.contains("make test"))
        XCTAssertTrue(markdown.contains("ERROR token=[REDACTED]"))
        XCTAssertTrue(markdown.contains("Inspect the repeated failure output before rerunning"))
        XCTAssertTrue(markdown.contains("pwd && git status --short --branch 2>/dev/null || true"))
        XCTAssertTrue(markdown.contains(CommandDiagnosticActionID.inspectRepeatContext.rawValue))
        XCTAssertTrue(markdown.contains("Inspect repeat context"))
        XCTAssertTrue(markdown.contains(CommandDiagnosticActionSafety.readOnly.rawValue))
        XCTAssertTrue(markdown.contains("expected working directory"))
        XCTAssertTrue(markdown.contains("first repeated failure output"))
        XCTAssertTrue(markdown.contains("The latest failures repeat, so capture location and Git state before another retry."))
        XCTAssertFalse(markdown.contains(secret))
    }

    func testCommandBlockDiagnosticsBuildsAIContext() throws {
        let blocks = [
            commandBlock(command: "make test", startedAt: 100, endedAt: 101, exitCode: 1, errorLine: "ERROR database is locked"),
            commandBlock(command: "make test", startedAt: 110, endedAt: 111, exitCode: 1, errorLine: "ERROR database is locked"),
            commandBlock(command: "make test", startedAt: 120, endedAt: 121, exitCode: 1, errorLine: "ERROR database is locked")
        ]

        let diagnostics = CommandBlockDiagnostics(blocks: blocks, redactSensitiveData: false)
        let context = try XCTUnwrap(diagnostics.aiContextText)

        XCTAssertTrue(context.contains("Session diagnostics:"))
        XCTAssertTrue(context.contains("Failed commands: 3"))
        XCTAssertTrue(context.contains("Latest failed command: make test"))
        XCTAssertTrue(context.contains("Recent failure diagnostic: ERROR database is locked"))
        XCTAssertTrue(context.contains("Recent failure fingerprint: error database is locked"))
        XCTAssertTrue(context.contains("Repeated failure diagnostic: 3x ERROR database is locked"))
        XCTAssertTrue(context.contains("Repeated failure match: exact"))
        XCTAssertTrue(context.contains("Repeated failure window:"))
        XCTAssertTrue(context.contains("Repeated failure duration: 20000 ms"))
        XCTAssertTrue(context.contains("Diagnostic severity: repeated"))
        XCTAssertTrue(context.contains("Diagnostic category: repeated"))
        XCTAssertTrue(context.contains("Diagnostic category evidence: ERROR database is locked"))
        XCTAssertTrue(context.contains("Diagnostic category confidence: medium"))
        XCTAssertTrue(context.contains("Suggested next inspection: Inspect the repeated failure output before rerunning"))
        XCTAssertTrue(context.contains("Suggested next command: pwd && git status --short --branch 2>/dev/null || true"))
        XCTAssertTrue(context.contains("Suggested next action id: inspect_repeat_context"))
        XCTAssertTrue(context.contains("Suggested next action source category: repeated"))
        XCTAssertTrue(context.contains("Suggested next action confidence: medium"))
        XCTAssertTrue(context.contains("Suggested next action title: Inspect repeat context"))
        XCTAssertTrue(context.contains("Suggested next action safety: read_only"))
        XCTAssertTrue(context.contains("Suggested next action rationale: The latest failures repeat"))
        XCTAssertTrue(context.contains("Suggested next action expected signals:"))
        XCTAssertTrue(context.contains("expected working directory"))
        XCTAssertTrue(context.contains("Suggested next action fallback steps:"))
        XCTAssertTrue(context.contains("first repeated failure output"))
        XCTAssertTrue(context.contains("Suggested next action requires confirmation: true"))
    }

    func testCommandBlockDiagnosticsGroupsNormalizedRepeatedFailures() throws {
        let diagnostics = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "make test",
                    startedAt: 100,
                    endedAt: 101,
                    exitCode: 1,
                    errorLine: "ERROR retry 1 failed at /tmp/build-1/output.log"
                ),
                commandBlock(
                    command: "make test",
                    startedAt: 110,
                    endedAt: 111,
                    exitCode: 1,
                    errorLine: "ERROR retry 2 failed at /tmp/build-2/output.log"
                ),
                commandBlock(
                    command: "make test",
                    startedAt: 120,
                    endedAt: 121,
                    exitCode: 1,
                    errorLine: "ERROR retry 3 failed at /tmp/build-3/output.log"
                )
            ],
            redactSensitiveData: false
        )
        let repeated = try XCTUnwrap(diagnostics.repeatedFailureDiagnostic)

        XCTAssertEqual(diagnostics.recentFailureFingerprint, "error retry <num> failed at <path>")
        XCTAssertEqual(repeated.count, 3)
        XCTAssertEqual(repeated.diagnostic, "ERROR retry 3 failed at /tmp/build-3/output.log")
        XCTAssertEqual(repeated.fingerprint, "error retry <num> failed at <path>")
        XCTAssertEqual(repeated.matchKind, .normalized)
        XCTAssertEqual(repeated.firstOccurredAt, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(repeated.latestOccurredAt, Date(timeIntervalSince1970: 121))
        XCTAssertEqual(repeated.durationMilliseconds, 20_000)
        XCTAssertEqual(diagnostics.diagnosticSeverity, .repeated)
    }

    func testCommandBlockDiagnosticsMarksCriticalFailure() {
        let diagnostics = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "deploy prod",
                    startedAt: 100,
                    endedAt: 101,
                    exitCode: 1,
                    errorLine: "fatal: permission denied"
                )
            ],
            redactSensitiveData: false
        )

        XCTAssertEqual(diagnostics.failedCommandCount, 1)
        XCTAssertEqual(diagnostics.diagnosticSeverity, .critical)
        XCTAssertEqual(diagnostics.diagnosticCategory, .permission)
        XCTAssertEqual(diagnostics.diagnosticCategoryEvidence, "fatal: permission denied")
        XCTAssertEqual(diagnostics.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(diagnostics.suggestedNextCommand, "pwd && id && ls -ld .")
        XCTAssertEqual(diagnostics.suggestedNextAction?.id, .inspectPermissions)
        XCTAssertEqual(diagnostics.suggestedNextAction?.sourceCategory, .permission)
        XCTAssertEqual(diagnostics.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(diagnostics.suggestedNextAction?.title, "Inspect current permissions")
        XCTAssertEqual(diagnostics.suggestedNextAction?.safety, .readOnly)
        XCTAssertEqual(diagnostics.suggestedNextAction?.expectedSignals.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.expectedSignals.first?.contains("expected directory") == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.fallbackNextSteps.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.fallbackNextSteps.first?.contains("parent directory") == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.requiresConfirmation, true)
    }

    func testCommandBlockDiagnosticsClassifiesCommonFailureCategories() {
        let portConflict = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "npm run dev",
                    startedAt: 100,
                    endedAt: 101,
                    exitCode: 1,
                    errorLine: "Error: listen EADDRINUSE: address already in use :::5173"
                )
            ],
            redactSensitiveData: false
        )
        let missingCommand = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "frobnicate",
                    startedAt: 110,
                    endedAt: 111,
                    exitCode: 127,
                    errorLine: "zsh: command not found: frobnicate"
                )
            ],
            redactSensitiveData: false
        )
        let missingFile = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "cat config.yml",
                    startedAt: 120,
                    endedAt: 121,
                    exitCode: 1,
                    errorLine: "cat: config.yml: No such file or directory"
                )
            ],
            redactSensitiveData: false
        )
        let gitFailure = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "git pull",
                    startedAt: 130,
                    endedAt: 131,
                    exitCode: 1,
                    errorLine: "fatal: not a git repository"
                )
            ],
            redactSensitiveData: false
        )
        let genericFailure = CommandBlockDiagnostics(
            blocks: [
                commandBlock(
                    command: "make check",
                    startedAt: 140,
                    endedAt: 141,
                    exitCode: 1,
                    errorLine: "ERROR validation failed"
                )
            ],
            redactSensitiveData: false
        )

        XCTAssertEqual(portConflict.diagnosticCategory, .portConflict)
        XCTAssertEqual(portConflict.diagnosticCategoryEvidence, "Error: listen EADDRINUSE: address already in use :::5173")
        XCTAssertEqual(portConflict.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(portConflict.suggestedNextCommand, "lsof -nP -iTCP -sTCP:LISTEN")
        XCTAssertEqual(portConflict.suggestedNextAction?.id, .listListeningPorts)
        XCTAssertEqual(portConflict.suggestedNextAction?.sourceCategory, .portConflict)
        XCTAssertEqual(portConflict.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(portConflict.suggestedNextAction?.title, "List listening TCP ports")
        XCTAssertEqual(portConflict.suggestedNextAction?.safety, .readOnly)
        XCTAssertTrue(portConflict.suggestedNextAction?.expectedSignals.first?.contains("conflicting local port") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.fallbackNextSteps.first?.contains("container") == true)
        XCTAssertEqual(missingCommand.diagnosticCategory, .missingCommand)
        XCTAssertEqual(missingCommand.diagnosticCategoryEvidence, "zsh: command not found: frobnicate")
        XCTAssertEqual(missingCommand.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(missingCommand.suggestedNextCommand, "echo \"$PATH\"")
        XCTAssertEqual(missingCommand.suggestedNextAction?.id, .inspectPath)
        XCTAssertEqual(missingCommand.suggestedNextAction?.sourceCategory, .missingCommand)
        XCTAssertEqual(missingCommand.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(missingCommand.suggestedNextAction?.title, "Inspect PATH")
        XCTAssertTrue(missingCommand.suggestedNextAction?.expectedSignals.first?.contains("PATH") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.fallbackNextSteps.first?.contains("command -v") == true)
        XCTAssertEqual(missingFile.diagnosticCategory, .missingFile)
        XCTAssertEqual(missingFile.diagnosticCategoryEvidence, "cat: config.yml: No such file or directory")
        XCTAssertEqual(missingFile.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(missingFile.suggestedNextCommand, "pwd && ls -la")
        XCTAssertEqual(missingFile.suggestedNextAction?.id, .inspectDirectory)
        XCTAssertEqual(missingFile.suggestedNextAction?.sourceCategory, .missingFile)
        XCTAssertEqual(missingFile.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(missingFile.suggestedNextAction?.title, "Inspect current directory")
        XCTAssertTrue(missingFile.suggestedNextAction?.expectedSignals.first?.contains("should contain the file") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.fallbackNextSteps.first?.contains("project tree") == true)
        XCTAssertEqual(gitFailure.diagnosticCategory, .git)
        XCTAssertEqual(gitFailure.diagnosticCategoryEvidence, "git pull")
        XCTAssertEqual(gitFailure.diagnosticCategoryConfidence, .medium)
        XCTAssertEqual(gitFailure.suggestedNextCommand, "git status --short --branch")
        XCTAssertEqual(gitFailure.suggestedNextAction?.id, .inspectGitState)
        XCTAssertEqual(gitFailure.suggestedNextAction?.sourceCategory, .git)
        XCTAssertEqual(gitFailure.suggestedNextAction?.confidence, .medium)
        XCTAssertEqual(gitFailure.suggestedNextAction?.title, "Inspect Git state")
        XCTAssertTrue(gitFailure.suggestedNextAction?.expectedSignals.first?.contains("current branch") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.fallbackNextSteps.first?.contains("remote") == true)
        XCTAssertEqual(genericFailure.diagnosticCategory, .generic)
        XCTAssertEqual(genericFailure.diagnosticCategoryEvidence, "ERROR validation failed")
        XCTAssertEqual(genericFailure.diagnosticCategoryConfidence, .low)
        XCTAssertEqual(genericFailure.suggestedNextAction?.id, .inspectLocalContext)
        XCTAssertEqual(genericFailure.suggestedNextAction?.sourceCategory, .generic)
        XCTAssertEqual(genericFailure.suggestedNextAction?.confidence, .low)
        XCTAssertEqual(genericFailure.suggestedNextAction?.title, "Inspect local context")
        XCTAssertTrue(genericFailure.suggestedNextAction?.expectedSignals.first?.contains("working directory") == true)
        XCTAssertTrue(genericFailure.suggestedNextAction?.fallbackNextSteps.first?.contains("exit code") == true)
    }

    func testSessionCommandStatsTracksRecentRedactedFailureDiagnostic() {
        let oldFailure = commandBlock(
            command: "swift test",
            startedAt: 100,
            endedAt: 101,
            exitCode: 1,
            errorLine: "ERROR older failure"
        )
        let latestSecret = "sk-abcdefghijklmnopqrstuvwxyz"
        let latestFailure = commandBlock(
            command: "swift build",
            startedAt: 120,
            endedAt: 121,
            exitCode: 2,
            errorLine: "ERROR token=\(latestSecret)"
        )
        let success = commandBlock(
            command: "swift format",
            startedAt: 130,
            endedAt: 131,
            exitCode: 0,
            errorLine: "ERROR should not count"
        )

        let stats = SessionCommandStats(
            blocks: [oldFailure, latestFailure, success],
            portCount: 0
        )

        XCTAssertEqual(stats.failureCount, 2)
        XCTAssertEqual(stats.recentFailureDiagnostic, "ERROR token=[REDACTED]")
        XCTAssertFalse(stats.recentFailureDiagnostic?.contains(latestSecret) ?? true)
    }

    func testSessionCommandStatsTracksRepeatedFailureDiagnostic() throws {
        let repeated = "ERROR database is locked"
        let blocks = [
            commandBlock(command: "make test", startedAt: 100, endedAt: 101, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 110, endedAt: 111, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 120, endedAt: 121, exitCode: 1, errorLine: repeated)
        ]

        let stats = SessionCommandStats(blocks: blocks, portCount: 0)
        let repeatedFailure = try XCTUnwrap(stats.repeatedFailureDiagnostic)

        XCTAssertEqual(repeatedFailure.count, 3)
        XCTAssertEqual(repeatedFailure.diagnostic, repeated)
    }

    func testSessionCommandStatsDoesNotRepeatAfterLatestSuccess() {
        let repeated = "ERROR database is locked"
        let blocks = [
            commandBlock(command: "make test", startedAt: 100, endedAt: 101, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 110, endedAt: 111, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 120, endedAt: 121, exitCode: 1, errorLine: repeated),
            commandBlock(command: "make test", startedAt: 130, endedAt: 131, exitCode: 0, errorLine: repeated)
        ]

        let stats = SessionCommandStats(blocks: blocks, portCount: 0)

        XCTAssertNil(stats.repeatedFailureDiagnostic)
    }

    private func commandBlock(
        command: String,
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        exitCode: Int32,
        errorLine: String
    ) -> TerminalCommandBlock {
        TerminalCommandBlock(
            id: UUID(),
            command: command,
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            exitCode: exitCode,
            outputTail: errorLine,
            outputCharacterCount: errorLine.count,
            outputSummary: TerminalOutputSummary(
                insightKinds: [.error],
                errorLine: errorLine,
                warningLine: nil,
                url: nil,
                filePath: nil,
                commitHash: nil,
                stackTraceLine: nil
            ),
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .shellIntegration
        )
    }

}
