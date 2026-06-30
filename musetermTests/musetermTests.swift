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
        XCTAssertTrue(script.contains("\"diagnostics\" => tab.fetch(\"commandDiagnostics\", {})"))
        XCTAssertTrue(script.contains("\"tools/call\""))
        XCTAssertTrue(script.contains("read_screen"))
        XCTAssertTrue(script.contains("send_key"))
    }

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

        XCTAssertEqual(encodedDiagnostics["failedCommandCount"] as? Int, 3)
        XCTAssertEqual(encodedDiagnostics["diagnosticSeverity"] as? String, CommandDiagnosticSeverity.repeated.rawValue)
        XCTAssertEqual(encodedDiagnostics["latestFailedCommand"] as? String, "make test")
        XCTAssertEqual(encodedDiagnostics["recentFailureDiagnostic"] as? String, diagnostic)
        XCTAssertEqual(
            encodedDiagnostics["suggestedNextInspection"] as? String,
            "Inspect the repeated failure output before rerunning: \(diagnostic)"
        )
        XCTAssertEqual(repeatedFailure["diagnostic"] as? String, diagnostic)
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
        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failed_command")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_inspection")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.repeated_failure")))
        XCTAssertTrue(markdown.contains("3"))
        XCTAssertTrue(markdown.contains(CommandDiagnosticSeverity.repeated.rawValue))
        XCTAssertTrue(markdown.contains("make test"))
        XCTAssertTrue(markdown.contains("ERROR token=[REDACTED]"))
        XCTAssertTrue(markdown.contains("Inspect the repeated failure output before rerunning"))
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
        XCTAssertTrue(context.contains("Repeated failure diagnostic: 3x ERROR database is locked"))
        XCTAssertTrue(context.contains("Diagnostic severity: repeated"))
        XCTAssertTrue(context.contains("Suggested next inspection: Inspect the repeated failure output before rerunning"))
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
