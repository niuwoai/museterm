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

    func testCliInputJsonReturnsResponseMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runMuseTermCLIRequestScript(
            fixture.scriptURL,
            home: fixture.root,
            arguments: ["input", "--json", "--timeout", "1.5", "--tab", "tab-1", "echo ok"],
            response: [
                "schemaVersion": 1,
                "app": "MuseTerm",
                "version": "test",
                "ok": true,
                "snapshotSequence": 43,
                "action": "input",
                "tabID": "tab-1",
                "message": "sent"
            ]
        )

        XCTAssertEqual(result.request["action"] as? String, "input")
        XCTAssertEqual(result.request["tab"] as? String, "tab-1")
        XCTAssertEqual(result.request["text"] as? String, "echo ok")
        XCTAssertEqual(result.output["schemaVersion"] as? Int, 1)
        XCTAssertEqual(result.output["version"] as? String, "test")
        XCTAssertEqual(result.output["snapshotSequence"] as? Int, 43)
        XCTAssertEqual(result.output["action"] as? String, "input")
        XCTAssertEqual(result.output["tabID"] as? String, "tab-1")
    }

    func testCliInstallerScriptExposesMCPAndTerminalCommands() {
        let script = MuseTermCLIInstaller.script

        XCTAssertTrue(script.contains("museterm tabs"))
        XCTAssertTrue(script.contains("museterm screen"))
        XCTAssertTrue(script.contains("museterm history"))
        XCTAssertTrue(script.contains("[--json]"))
        XCTAssertTrue(script.contains("\"metadata\" => { \"type\" => \"boolean\""))
        XCTAssertTrue(script.contains("text_payload(state, tab, \"screen\", args[\"chars\"])"))
        XCTAssertTrue(script.contains("text_payload(state, tab, \"history\", args[\"chars\"])"))
        XCTAssertTrue(script.contains("museterm input"))
        XCTAssertTrue(script.contains("museterm key"))
        XCTAssertTrue(script.contains("print_json(response)"))
        XCTAssertTrue(script.contains("--timeout SECONDS"))
        XCTAssertTrue(script.contains("timeout must be positive."))
        XCTAssertTrue(script.contains("return JSON response metadata"))
        XCTAssertTrue(script.contains("commands_payload"))
        XCTAssertTrue(script.contains("\"schemaVersion\" => state[\"schemaVersion\"]"))
        XCTAssertTrue(script.contains("\"snapshotSequence\" => state[\"snapshotSequence\"]"))
        XCTAssertTrue(script.contains("\"outputTailCharacters\""))
        XCTAssertTrue(script.contains("\"outputTailReturnedCharacters\""))
        XCTAssertTrue(script.contains("\"outputTailLimit\""))
        XCTAssertTrue(script.contains("\"outputTailTruncated\""))
        XCTAssertTrue(script.contains("\"outputTailStoredTruncated\""))
        XCTAssertTrue(script.contains("commands_payload(state, tab, chars)"))
        XCTAssertTrue(script.contains("commands_payload(state, tab, args[\"chars\"])"))
        XCTAssertTrue(script.contains("\"commandCount\" => source_blocks.length"))
        XCTAssertTrue(script.contains("\"returnedCommandCount\" => blocks.length"))
        XCTAssertTrue(script.contains("\"diagnostics\" => tab.fetch(\"commandDiagnostics\", {})"))
        XCTAssertTrue(script.contains("\"tools/call\""))
        XCTAssertTrue(script.contains("read_screen"))
        XCTAssertTrue(script.contains("send_key"))
    }

    func testCliCommandsReportsOutputTailTruncationMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let limited = try runMuseTermCLIScript(fixture.scriptURL, home: fixture.root, arguments: ["commands", "--chars", "3"])
        let limitedCommand = try XCTUnwrap((limited["commands"] as? [[String: Any]])?.first)
        XCTAssertEqual(limited["schemaVersion"] as? Int, 1)
        XCTAssertEqual(limited["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(limited["tabID"] as? String, "tab-1")
        XCTAssertEqual(limited["selectedTabID"] as? String, "tab-1")
        XCTAssertEqual(limited["commandCount"] as? Int, 1)
        XCTAssertEqual(limited["returnedCommandCount"] as? Int, 1)
        XCTAssertEqual(limited["outputTailLimit"] as? Int, 3)
        XCTAssertEqual(limitedCommand["outputTail"] as? String, "def")
        XCTAssertEqual(limitedCommand["outputTailCharacters"] as? Int, 6)
        XCTAssertEqual(limitedCommand["outputTailReturnedCharacters"] as? Int, 3)
        XCTAssertEqual(limitedCommand["outputTailLimit"] as? Int, 3)
        XCTAssertEqual(limitedCommand["outputTailTruncated"] as? Bool, true)
        XCTAssertEqual(limitedCommand["outputTailStoredTruncated"] as? Bool, true)

        let unlimited = try runMuseTermCLIScript(fixture.scriptURL, home: fixture.root, arguments: ["commands"])
        let unlimitedCommand = try XCTUnwrap((unlimited["commands"] as? [[String: Any]])?.first)
        XCTAssertTrue(unlimited["outputTailLimit"] is NSNull)
        XCTAssertEqual(unlimitedCommand["outputTail"] as? String, "abcdef")
        XCTAssertEqual(unlimitedCommand["outputTailCharacters"] as? Int, 6)
        XCTAssertEqual(unlimitedCommand["outputTailReturnedCharacters"] as? Int, 6)
        XCTAssertTrue(unlimitedCommand["outputTailLimit"] is NSNull)
        XCTAssertEqual(unlimitedCommand["outputTailTruncated"] as? Bool, false)
        XCTAssertEqual(unlimitedCommand["outputTailStoredTruncated"] as? Bool, true)

        let screen = try runMuseTermCLIScript(fixture.scriptURL, home: fixture.root, arguments: ["screen", "--chars", "4", "--json"])
        XCTAssertEqual(screen["schemaVersion"] as? Int, 1)
        XCTAssertEqual(screen["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(screen["field"] as? String, "screen")
        XCTAssertEqual(screen["text"] as? String, "cdef")
        XCTAssertEqual(screen["textCharacters"] as? Int, 13)
        XCTAssertEqual(screen["returnedCharacters"] as? Int, 4)
        XCTAssertEqual(screen["limit"] as? Int, 4)
        XCTAssertEqual(screen["truncated"] as? Bool, true)

        let history = try runMuseTermCLIScript(fixture.scriptURL, home: fixture.root, arguments: ["history", "--json"])
        XCTAssertEqual(history["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(history["field"] as? String, "history")
        XCTAssertEqual(history["text"] as? String, "history-abcdef")
        XCTAssertEqual(history["textCharacters"] as? Int, 14)
        XCTAssertEqual(history["returnedCharacters"] as? Int, 14)
        XCTAssertTrue(history["limit"] is NSNull)
        XCTAssertEqual(history["truncated"] as? Bool, false)
    }

    func testMCPReadCommandsReportsPayloadMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try runMuseTermMCPRequest(
            fixture.scriptURL,
            home: fixture.root,
            request: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "read_commands",
                    "arguments": [
                        "chars": 2
                    ]
                ]
            ]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
        let command = try XCTUnwrap(commands.first)

        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(payload["tabID"] as? String, "tab-1")
        XCTAssertEqual(payload["selectedTabID"] as? String, "tab-1")
        XCTAssertEqual(payload["commandCount"] as? Int, 1)
        XCTAssertEqual(payload["returnedCommandCount"] as? Int, 1)
        XCTAssertEqual(payload["outputTailLimit"] as? Int, 2)
        XCTAssertEqual(command["outputTail"] as? String, "ef")
        XCTAssertEqual(command["outputTailReturnedCharacters"] as? Int, 2)
        XCTAssertEqual(command["outputTailTruncated"] as? Bool, true)
    }

    func testMCPSendTextReportsResponseMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runMuseTermMCPRequestWithToolResponse(
            fixture.scriptURL,
            home: fixture.root,
            request: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "send_text",
                    "arguments": [
                        "tab": "tab-1",
                        "text": "echo ok",
                        "timeout": 1.5,
                        "metadata": true
                    ]
                ]
            ],
            response: [
                "schemaVersion": 1,
                "app": "MuseTerm",
                "version": "test",
                "ok": true,
                "snapshotSequence": 44,
                "action": "input",
                "tabID": "tab-1",
                "message": "sent"
            ]
        )
        let response = result.response
        let request = result.toolRequest
        let resultObject = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(resultObject["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(request["action"] as? String, "input")
        XCTAssertEqual(request["tab"] as? String, "tab-1")
        XCTAssertEqual(request["text"] as? String, "echo ok")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["snapshotSequence"] as? Int, 44)
        XCTAssertEqual(payload["action"] as? String, "input")
        XCTAssertEqual(payload["tabID"] as? String, "tab-1")
    }

    func testMCPReadScreenReportsMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try runMuseTermMCPRequest(
            fixture.scriptURL,
            home: fixture.root,
            request: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "read_screen",
                    "arguments": [
                        "chars": 5,
                        "metadata": true
                    ]
                ]
            ]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(payload["field"] as? String, "screen")
        XCTAssertEqual(payload["text"] as? String, "bcdef")
        XCTAssertEqual(payload["textCharacters"] as? Int, 13)
        XCTAssertEqual(payload["returnedCharacters"] as? Int, 5)
        XCTAssertEqual(payload["limit"] as? Int, 5)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }

    func testMCPListTabsReportsMetadata() throws {
        let fixture = try makeMuseTermCLITestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try runMuseTermMCPRequest(
            fixture.scriptURL,
            home: fixture.root,
            request: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "list_tabs",
                    "arguments": [
                        "metadata": true
                    ]
                ]
            ]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let tabs = try XCTUnwrap(payload["tabs"] as? [[String: Any]])
        let tab = try XCTUnwrap(tabs.first)

        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["snapshotSequence"] as? Int, 42)
        XCTAssertEqual(payload["app"] as? String, "MuseTerm")
        XCTAssertEqual(payload["version"] as? String, "test")
        XCTAssertEqual(payload["selectedTabID"] as? String, "tab-1")
        XCTAssertEqual(tab["id"] as? String, "tab-1")
        XCTAssertEqual(tab["title"] as? String, "project")
        XCTAssertEqual(tab["isSelected"] as? Bool, true)
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
        let priorityFactors = try XCTUnwrap(encodedDiagnostics["diagnosticPriorityFactors"] as? [String])
        let state = TerminalToolState(
            app: "MuseTerm",
            version: "test",
            snapshotSequence: 7,
            updatedAt: Date(timeIntervalSince1970: 130),
            selectedTabID: "tab-1",
            tabs: [snapshot]
        )
        let stateData = try JSONEncoder().encode(state)
        let stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])

        XCTAssertEqual(stateObject["schemaVersion"] as? Int, 1)
        XCTAssertEqual(stateObject["snapshotSequence"] as? Int, 7)
        XCTAssertEqual(encodedDiagnostics["schemaVersion"] as? Int, 1)
        XCTAssertEqual(encodedDiagnostics["failedCommandCount"] as? Int, 3)
        XCTAssertEqual(encodedDiagnostics["diagnosticPriorityScore"] as? Int, 90)
        XCTAssertEqual(
            priorityFactors,
            [
                CommandDiagnosticPriorityFactor.failedCommand.rawValue,
                CommandDiagnosticPriorityFactor.repeatedSeverity.rawValue,
                CommandDiagnosticPriorityFactor.repeatedCategory.rawValue,
                CommandDiagnosticPriorityFactor.mediumConfidenceCategory.rawValue,
                CommandDiagnosticPriorityFactor.multipleFailures.rawValue,
                CommandDiagnosticPriorityFactor.repeatedFailureCount.rawValue
            ]
        )
        XCTAssertEqual(encodedDiagnostics["diagnosticSeverity"] as? String, CommandDiagnosticSeverity.repeated.rawValue)
        XCTAssertEqual(encodedDiagnostics["diagnosticCategory"] as? String, CommandDiagnosticCategory.repeated.rawValue)
        XCTAssertEqual(encodedDiagnostics["diagnosticCategoryEvidence"] as? String, diagnostic)
        XCTAssertEqual(
            encodedDiagnostics["diagnosticCategoryConfidence"] as? String,
            CommandDiagnosticConfidence.medium.rawValue
        )
        XCTAssertEqual(encodedDiagnostics["latestFailedCommand"] as? String, "make test")
        XCTAssertEqual(encodedDiagnostics["latestFailedExitCode"] as? Int, 1)
        XCTAssertEqual(encodedDiagnostics["latestFailedDurationMilliseconds"] as? Int, 1_000)
        XCTAssertEqual(encodedDiagnostics["latestFailedCompletionSource"] as? String, "shellIntegration")
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
        XCTAssertEqual(suggestedNextAction["priorityScore"] as? Int, 90)
        XCTAssertEqual(suggestedNextAction["priorityFactors"] as? [String], priorityFactors)
        let evidenceAnchors = try XCTUnwrap(suggestedNextAction["evidenceAnchors"] as? [String])
        XCTAssertEqual(
            evidenceAnchors,
            [
                CommandDiagnosticEvidenceAnchor.latestFailedCommand.rawValue,
                CommandDiagnosticEvidenceAnchor.recentFailureDiagnostic.rawValue,
                CommandDiagnosticEvidenceAnchor.recentFailureFingerprint.rawValue,
                CommandDiagnosticEvidenceAnchor.repeatedFailureDiagnostic.rawValue,
                CommandDiagnosticEvidenceAnchor.diagnosticCategoryEvidence.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["actionScope"] as? String,
            CommandDiagnosticActionScope.repeatedFailureContext.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["expectedResultKind"] as? String,
            CommandDiagnosticActionResultKind.contextSnapshot.rawValue
        )
        let expectedResultFields = try XCTUnwrap(suggestedNextAction["expectedResultFields"] as? [String])
        XCTAssertEqual(
            expectedResultFields,
            [
                CommandDiagnosticActionResultField.workingDirectory.rawValue,
                CommandDiagnosticActionResultField.gitBranch.rawValue,
                CommandDiagnosticActionResultField.gitUpstream.rawValue,
                CommandDiagnosticActionResultField.gitDirtyState.rawValue
            ]
        )
        let expectedResultSignals = try XCTUnwrap(suggestedNextAction["expectedResultSignals"] as? [String])
        XCTAssertEqual(
            expectedResultSignals,
            [
                CommandDiagnosticActionResultSignal.workingDirectoryVisible.rawValue,
                CommandDiagnosticActionResultSignal.gitStateVisible.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultParsingHints"] as? [String],
            [
                CommandDiagnosticActionResultParsingHint.commandSequenceOutput.rawValue,
                CommandDiagnosticActionResultParsingHint.optionalGitStatusOutput.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultInterpretationHints"] as? [String],
            [
                CommandDiagnosticActionResultInterpretationHint.gitOutputOptional.rawValue,
                CommandDiagnosticActionResultInterpretationHint.compareAgainstFirstFailure.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultDecisionHints"] as? [String],
            [
                CommandDiagnosticActionResultDecisionHint.unchangedContextDiscouragesRetry.rawValue,
                CommandDiagnosticActionResultDecisionHint.changedContextNeedsComparison.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultCaveats"] as? [String],
            [
                CommandDiagnosticActionResultCaveat.contextSnapshotIsPartial.rawValue,
                CommandDiagnosticActionResultCaveat.firstFailureOutputMayStillBeNeeded.rawValue
            ]
        )
        let sensitiveResultFields = try XCTUnwrap(suggestedNextAction["sensitiveResultFields"] as? [String])
        XCTAssertEqual(
            sensitiveResultFields,
            [
                CommandDiagnosticActionResultField.workingDirectory.rawValue,
                CommandDiagnosticActionResultField.gitBranch.rawValue,
                CommandDiagnosticActionResultField.gitUpstream.rawValue
            ]
        )
        let resultRedactionHints = try XCTUnwrap(suggestedNextAction["resultRedactionHints"] as? [String])
        XCTAssertEqual(
            resultRedactionHints,
            [
                CommandDiagnosticActionRedactionHint.workingDirectory.rawValue,
                CommandDiagnosticActionRedactionHint.gitBranch.rawValue,
                CommandDiagnosticActionRedactionHint.gitUpstream.rawValue
            ]
        )
        let resultRefreshTriggers = try XCTUnwrap(suggestedNextAction["resultRefreshTriggers"] as? [String])
        XCTAssertEqual(
            resultRefreshTriggers,
            [
                CommandDiagnosticActionRefreshTrigger.workingDirectoryChanged.rawValue,
                CommandDiagnosticActionRefreshTrigger.gitStateChanged.rawValue,
                CommandDiagnosticActionRefreshTrigger.failureContextChanged.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultPrivacyLevel"] as? String,
            CommandDiagnosticActionPrivacyLevel.sensitive.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultSharingPolicy"] as? String,
            CommandDiagnosticActionSharingPolicy.localOnly.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultRetentionPolicy"] as? String,
            CommandDiagnosticActionRetentionPolicy.localSessionOnly.rawValue
        )
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
        let preflightChecks = try XCTUnwrap(suggestedNextAction["preflightChecks"] as? [String])
        XCTAssertEqual(preflightChecks.count, 2)
        XCTAssertTrue(preflightChecks[0].contains("anything meaningful changed"))
        let automationGuardrails = try XCTUnwrap(suggestedNextAction["automationGuardrails"] as? [String])
        XCTAssertEqual(automationGuardrails.count, 2)
        XCTAssertTrue(automationGuardrails[0].contains("same failing command"))
        let userDecisionPoints = try XCTUnwrap(suggestedNextAction["userDecisionPoints"] as? [String])
        XCTAssertEqual(userDecisionPoints.count, 2)
        XCTAssertTrue(userDecisionPoints[0].contains("context changed"))
        let completionCriteria = try XCTUnwrap(suggestedNextAction["completionCriteria"] as? [String])
        XCTAssertEqual(completionCriteria.count, 2)
        XCTAssertTrue(completionCriteria[0].contains("material context change"))
        let fallbackNextSteps = try XCTUnwrap(suggestedNextAction["fallbackNextSteps"] as? [String])
        XCTAssertEqual(fallbackNextSteps.count, 2)
        XCTAssertTrue(fallbackNextSteps[0].contains("first repeated failure output"))
        XCTAssertEqual(suggestedNextAction["safety"] as? String, CommandDiagnosticActionSafety.readOnly.rawValue)
        XCTAssertEqual(
            suggestedNextAction["executionMode"] as? String,
            CommandDiagnosticActionExecutionMode.stageOnly.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["executionTarget"] as? String,
            CommandDiagnosticActionExecutionTarget.currentTerminalSession.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultValidityScope"] as? String,
            CommandDiagnosticActionResultValidityScope.currentTerminalSession.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultFreshnessPolicy"] as? String,
            CommandDiagnosticActionResultFreshnessPolicy.failureAttemptBound.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultReuseKeyFields"] as? [String],
            [
                CommandDiagnosticActionResultReuseKeyField.terminalSession.rawValue,
                CommandDiagnosticActionResultReuseKeyField.workingDirectory.rawValue,
                CommandDiagnosticActionResultReuseKeyField.gitRepository.rawValue,
                CommandDiagnosticActionResultReuseKeyField.failureFingerprint.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["resultReusePolicy"] as? String,
            CommandDiagnosticActionResultReusePolicy.doNotReuseAcrossAttempts.rawValue
        )
        XCTAssertEqual(
            suggestedNextAction["resultReuseValidationChecks"] as? [String],
            [
                CommandDiagnosticActionResultReuseValidationCheck.matchFailureFingerprint.rawValue,
                CommandDiagnosticActionResultReuseValidationCheck.matchWorkingDirectory.rawValue,
                CommandDiagnosticActionResultReuseValidationCheck.doNotCrossAttemptBoundary.rawValue
            ]
        )
        XCTAssertEqual(
            suggestedNextAction["retryCondition"] as? String,
            CommandDiagnosticActionRetryCondition.contextChangedOrFirstFailureInspected.rawValue
        )
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
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_priority_score")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_priority_factors")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_severity")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category_evidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.diagnostic_category_confidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.failure_fingerprint")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failed_command")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failed_duration")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.latest_failed_completion_source")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_inspection")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_command")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_id")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_source_category")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_confidence")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_priority_score")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_priority_factors")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_evidence_anchors")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_scope")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_expected_result_kind")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_expected_result_fields")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_expected_result_signals")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_parsing_hints")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_interpretation_hints")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_decision_hints")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_caveats")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_sensitive_result_fields")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_redaction_hints")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_refresh_triggers")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_privacy_level")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_sharing_policy")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_retention_policy")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_safety")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_execution_mode")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_execution_target")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_validity_scope")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_freshness_policy")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_reuse_key_fields")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_reuse_policy")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_result_reuse_validation_checks")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_retry_condition")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_preflight_checks")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_automation_guardrails")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_user_decision_points")))
        XCTAssertTrue(markdown.contains(L10n.string("runbook.suggested_next_action_completion_criteria")))
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
        XCTAssertTrue(markdown.contains("1000 ms"))
        XCTAssertTrue(markdown.contains("shellIntegration"))
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
        XCTAssertTrue(context.contains("Diagnostic priority score: 90"))
        XCTAssertTrue(context.contains("Diagnostic priority factors: failed_command; repeated_severity"))
        XCTAssertTrue(context.contains("multiple_failures; repeated_failure_count"))
        XCTAssertTrue(context.contains("Latest failed command: make test"))
        XCTAssertTrue(context.contains("Latest failed exit code: 1"))
        XCTAssertTrue(context.contains("Latest failed duration: 1000 ms"))
        XCTAssertTrue(context.contains("Latest failed completion source: shellIntegration"))
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
        XCTAssertTrue(context.contains("Suggested next action priority score: 90"))
        XCTAssertTrue(context.contains("Suggested next action priority factors: failed_command; repeated_severity"))
        XCTAssertTrue(context.contains("multiple_failures; repeated_failure_count"))
        XCTAssertTrue(context.contains("Suggested next action evidence anchors: latest_failed_command; recent_failure_diagnostic"))
        XCTAssertTrue(context.contains("repeated_failure_diagnostic; diagnostic_category_evidence"))
        XCTAssertTrue(context.contains("Suggested next action scope: repeated_failure_context"))
        XCTAssertTrue(context.contains("Suggested next action expected result kind: context_snapshot"))
        XCTAssertTrue(context.contains("Suggested next action expected result fields: working_directory; git_branch"))
        XCTAssertTrue(context.contains("git_upstream; git_dirty_state"))
        XCTAssertTrue(context.contains("Suggested next action expected result signals: working_directory_visible; git_state_visible"))
        XCTAssertTrue(context.contains("Suggested next action result parsing hints: command_sequence_output; optional_git_status_output"))
        XCTAssertTrue(context.contains("Suggested next action result interpretation hints: git_output_optional; compare_against_first_failure"))
        XCTAssertTrue(context.contains("Suggested next action result decision hints: unchanged_context_discourages_retry; changed_context_needs_comparison"))
        XCTAssertTrue(context.contains("Suggested next action result caveats: context_snapshot_is_partial; first_failure_output_may_still_be_needed"))
        XCTAssertTrue(context.contains("Suggested next action sensitive result fields: working_directory; git_branch; git_upstream"))
        XCTAssertTrue(context.contains("Suggested next action result redaction hints: working_directory; git_branch; git_upstream"))
        XCTAssertTrue(context.contains("Suggested next action result refresh triggers: working_directory_changed; git_state_changed; failure_context_changed"))
        XCTAssertTrue(context.contains("Suggested next action result privacy level: sensitive"))
        XCTAssertTrue(context.contains("Suggested next action result sharing policy: local_only"))
        XCTAssertTrue(context.contains("Suggested next action result retention policy: local_session_only"))
        XCTAssertTrue(context.contains("Suggested next action title: Inspect repeat context"))
        XCTAssertTrue(context.contains("Suggested next action safety: read_only"))
        XCTAssertTrue(context.contains("Suggested next action execution mode: stage_only"))
        XCTAssertTrue(context.contains("Suggested next action execution target: current_terminal_session"))
        XCTAssertTrue(context.contains("Suggested next action result validity scope: current_terminal_session"))
        XCTAssertTrue(context.contains("Suggested next action result freshness policy: failure_attempt_bound"))
        XCTAssertTrue(
            context.contains(
                "Suggested next action result reuse key fields: terminal_session; working_directory; git_repository; failure_fingerprint"
            )
        )
        XCTAssertTrue(context.contains("Suggested next action result reuse policy: do_not_reuse_across_attempts"))
        XCTAssertTrue(
            context.contains(
                "Suggested next action result reuse validation checks: match_failure_fingerprint; match_working_directory; do_not_cross_attempt_boundary"
            )
        )
        XCTAssertTrue(context.contains("Suggested next action retry condition: context_changed_or_first_failure_inspected"))
        XCTAssertTrue(context.contains("Suggested next action preflight checks:"))
        XCTAssertTrue(context.contains("anything meaningful changed"))
        XCTAssertTrue(context.contains("Suggested next action automation guardrails:"))
        XCTAssertTrue(context.contains("same failing command"))
        XCTAssertTrue(context.contains("Suggested next action user decision points:"))
        XCTAssertTrue(context.contains("context changed"))
        XCTAssertTrue(context.contains("Suggested next action completion criteria:"))
        XCTAssertTrue(context.contains("material context change"))
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
        XCTAssertEqual(diagnostics.diagnosticPriorityScore, 100)
        XCTAssertEqual(
            diagnostics.diagnosticPriorityFactors,
            [
                .failedCommand,
                .criticalSeverity,
                .permissionCategory,
                .highConfidenceCategory
            ]
        )
        XCTAssertEqual(diagnostics.diagnosticCategory, .permission)
        XCTAssertEqual(diagnostics.diagnosticCategoryEvidence, "fatal: permission denied")
        XCTAssertEqual(diagnostics.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(diagnostics.suggestedNextCommand, "pwd && id && ls -ld .")
        XCTAssertEqual(diagnostics.suggestedNextAction?.id, .inspectPermissions)
        XCTAssertEqual(diagnostics.suggestedNextAction?.sourceCategory, .permission)
        XCTAssertEqual(diagnostics.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(diagnostics.suggestedNextAction?.priorityScore, 100)
        XCTAssertEqual(diagnostics.suggestedNextAction?.priorityFactors, diagnostics.diagnosticPriorityFactors)
        XCTAssertTrue(diagnostics.suggestedNextAction?.evidenceAnchors.contains(.latestFailedCommand) == true)
        XCTAssertTrue(diagnostics.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.actionScope, .permissionBoundary)
        XCTAssertEqual(diagnostics.suggestedNextAction?.expectedResultKind, .identityAndPermissions)
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.expectedResultFields,
            [.workingDirectory, .currentUser, .directoryPermissions]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.expectedResultSignals,
            [.currentUserVisible, .permissionBoundaryVisible]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultParsingHints,
            [.commandSequenceOutput, .lineOrientedText]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultInterpretationHints,
            [.compareUserAndPermissions, .mismatchExplainsPermissionFailure]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultDecisionHints,
            [.permissionMismatchNeedsExplicitElevation, .ownershipChangeRequiresApproval]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultCaveats,
            [.permissionsArePathScoped, .sudoOrRemoteContextMayDiffer]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.sensitiveResultFields,
            [.workingDirectory, .currentUser, .directoryPermissions]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultRedactionHints,
            [.workingDirectory, .userIdentity, .permissionMetadata]
        )
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultRefreshTriggers,
            [.workingDirectoryChanged, .userContextChanged, .permissionsChanged]
        )
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultPrivacyLevel, .sensitive)
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultSharingPolicy, .localOnly)
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultRetentionPolicy, .localSessionOnly)
        XCTAssertEqual(diagnostics.suggestedNextAction?.title, "Inspect current permissions")
        XCTAssertEqual(diagnostics.suggestedNextAction?.safety, .readOnly)
        XCTAssertEqual(diagnostics.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(diagnostics.suggestedNextAction?.executionTarget, .currentWorkingDirectory)
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultValidityScope, .currentWorkingDirectory)
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultFreshnessPolicy, .contextBound)
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultReuseKeyFields,
            [.workingDirectory, .userIdentity, .permissionMetadata]
        )
        XCTAssertEqual(diagnostics.suggestedNextAction?.resultReusePolicy, .reuseWhenKeysMatch)
        XCTAssertEqual(
            diagnostics.suggestedNextAction?.resultReuseValidationChecks,
            [.matchReuseKeys, .matchWorkingDirectory, .matchUserIdentity]
        )
        XCTAssertEqual(diagnostics.suggestedNextAction?.retryCondition, .permissionsVerified)
        XCTAssertEqual(diagnostics.suggestedNextAction?.preflightChecks.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.preflightChecks.first?.contains("insufficient permissions") == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.automationGuardrails.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.automationGuardrails.first?.contains("sudo") == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.userDecisionPoints.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.userDecisionPoints.first?.contains("elevated privileges") == true)
        XCTAssertEqual(diagnostics.suggestedNextAction?.completionCriteria.count, 2)
        XCTAssertTrue(diagnostics.suggestedNextAction?.completionCriteria.first?.contains("permission boundary") == true)
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
        XCTAssertEqual(portConflict.diagnosticPriorityScore, 56)
        XCTAssertEqual(
            portConflict.diagnosticPriorityFactors,
            [.failedCommand, .failedSeverity, .portConflictCategory, .highConfidenceCategory]
        )
        XCTAssertEqual(portConflict.diagnosticCategoryEvidence, "Error: listen EADDRINUSE: address already in use :::5173")
        XCTAssertEqual(portConflict.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(portConflict.suggestedNextCommand, "lsof -nP -iTCP -sTCP:LISTEN")
        XCTAssertEqual(portConflict.suggestedNextAction?.id, .listListeningPorts)
        XCTAssertEqual(portConflict.suggestedNextAction?.sourceCategory, .portConflict)
        XCTAssertEqual(portConflict.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(portConflict.suggestedNextAction?.priorityScore, 56)
        XCTAssertEqual(portConflict.suggestedNextAction?.priorityFactors, portConflict.diagnosticPriorityFactors)
        XCTAssertTrue(portConflict.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(portConflict.suggestedNextAction?.actionScope, .localNetwork)
        XCTAssertEqual(portConflict.suggestedNextAction?.expectedResultKind, .listeningPorts)
        XCTAssertEqual(
            portConflict.suggestedNextAction?.expectedResultFields,
            [.localPort, .processID, .processName, .listenAddress]
        )
        XCTAssertEqual(
            portConflict.suggestedNextAction?.expectedResultSignals,
            [.targetPortVisible, .ownerProcessVisible]
        )
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultParsingHints,
            [.lineOrientedText, .whitespaceSeparatedColumns]
        )
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultInterpretationHints,
            [.emptyOutputMeansNoLocalListener, .rowsIdentifyOwners]
        )
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultDecisionHints,
            [.portOwnerRequiresUserDecision, .noLocalListenerSuggestsScopeCheck]
        )
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultCaveats,
            [.localNetworkNamespaceOnly, .containerOrRemoteListenersMayBeMissing]
        )
        XCTAssertEqual(portConflict.suggestedNextAction?.sensitiveResultFields, [.processName, .listenAddress])
        XCTAssertEqual(portConflict.suggestedNextAction?.resultRedactionHints, [.processIdentity, .networkAddress])
        XCTAssertEqual(portConflict.suggestedNextAction?.resultRefreshTriggers, [.processStateChanged, .networkListenersChanged])
        XCTAssertEqual(portConflict.suggestedNextAction?.resultPrivacyLevel, .contextual)
        XCTAssertEqual(portConflict.suggestedNextAction?.resultSharingPolicy, .redactBeforeSharing)
        XCTAssertEqual(portConflict.suggestedNextAction?.resultRetentionPolicy, .persistRedactedSummary)
        XCTAssertEqual(portConflict.suggestedNextAction?.title, "List listening TCP ports")
        XCTAssertEqual(portConflict.suggestedNextAction?.safety, .readOnly)
        XCTAssertEqual(portConflict.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(portConflict.suggestedNextAction?.executionTarget, .currentTerminalNetworkNamespace)
        XCTAssertEqual(portConflict.suggestedNextAction?.resultValidityScope, .currentTerminalNetworkNamespace)
        XCTAssertEqual(portConflict.suggestedNextAction?.resultFreshnessPolicy, .liveSnapshot)
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultReuseKeyFields,
            [.terminalNetworkNamespace, .networkListeners]
        )
        XCTAssertEqual(portConflict.suggestedNextAction?.resultReusePolicy, .refreshBeforeUse)
        XCTAssertEqual(
            portConflict.suggestedNextAction?.resultReuseValidationChecks,
            [.refreshDynamicSnapshot, .matchNetworkNamespace, .matchObservedSignal]
        )
        XCTAssertEqual(portConflict.suggestedNextAction?.retryCondition, .portConflictResolvedOrOwnerKnown)
        XCTAssertTrue(portConflict.suggestedNextAction?.preflightChecks.first?.contains("local TCP port") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.automationGuardrails.first?.contains("kill") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.userDecisionPoints.first?.contains("owning process") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.completionCriteria.first?.contains("port owner") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.expectedSignals.first?.contains("conflicting local port") == true)
        XCTAssertTrue(portConflict.suggestedNextAction?.fallbackNextSteps.first?.contains("container") == true)
        XCTAssertEqual(missingCommand.diagnosticCategory, .missingCommand)
        XCTAssertEqual(missingCommand.diagnosticPriorityScore, 54)
        XCTAssertEqual(
            missingCommand.diagnosticPriorityFactors,
            [.failedCommand, .failedSeverity, .missingCommandCategory, .highConfidenceCategory]
        )
        XCTAssertEqual(missingCommand.diagnosticCategoryEvidence, "zsh: command not found: frobnicate")
        XCTAssertEqual(missingCommand.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(missingCommand.suggestedNextCommand, "echo \"$PATH\"")
        XCTAssertEqual(missingCommand.suggestedNextAction?.id, .inspectPath)
        XCTAssertEqual(missingCommand.suggestedNextAction?.sourceCategory, .missingCommand)
        XCTAssertEqual(missingCommand.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(missingCommand.suggestedNextAction?.priorityScore, 54)
        XCTAssertEqual(missingCommand.suggestedNextAction?.priorityFactors, missingCommand.diagnosticPriorityFactors)
        XCTAssertTrue(missingCommand.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(missingCommand.suggestedNextAction?.actionScope, .shellEnvironment)
        XCTAssertEqual(missingCommand.suggestedNextAction?.expectedResultKind, .shellPath)
        XCTAssertEqual(missingCommand.suggestedNextAction?.expectedResultFields, [.pathEntries])
        XCTAssertEqual(missingCommand.suggestedNextAction?.expectedResultSignals, [.pathEntriesVisible])
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultParsingHints, [.pathList])
        XCTAssertEqual(
            missingCommand.suggestedNextAction?.resultInterpretationHints,
            [.pathEntryPresenceMatters, .missingPathEntryExplainsCommandFailure]
        )
        XCTAssertEqual(
            missingCommand.suggestedNextAction?.resultDecisionHints,
            [.missingPathEntrySuggestsActivationOrInstall, .installationRequiresUserChoice]
        )
        XCTAssertEqual(
            missingCommand.suggestedNextAction?.resultCaveats,
            [.pathIsShellSpecific, .toolMayExistOutsidePath]
        )
        XCTAssertEqual(missingCommand.suggestedNextAction?.sensitiveResultFields, [.pathEntries])
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultRedactionHints, [.shellPathEntries])
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultRefreshTriggers, [.shellEnvironmentChanged])
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultPrivacyLevel, .sensitive)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultSharingPolicy, .localOnly)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultRetentionPolicy, .localSessionOnly)
        XCTAssertEqual(missingCommand.suggestedNextAction?.title, "Inspect PATH")
        XCTAssertEqual(missingCommand.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(missingCommand.suggestedNextAction?.executionTarget, .currentShellEnvironment)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultValidityScope, .currentShellEnvironment)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultFreshnessPolicy, .contextBound)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultReuseKeyFields, [.shellEnvironment])
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultReusePolicy, .reuseWhenKeysMatch)
        XCTAssertEqual(missingCommand.suggestedNextAction?.resultReuseValidationChecks, [.matchReuseKeys, .matchShellEnvironment])
        XCTAssertEqual(missingCommand.suggestedNextAction?.retryCondition, .commandAvailableOnPath)
        XCTAssertTrue(missingCommand.suggestedNextAction?.preflightChecks.first?.contains("missing executable") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.automationGuardrails.first?.contains("install packages") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.userDecisionPoints.first?.contains("install the missing tool") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.completionCriteria.first?.contains("executable resolves") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.expectedSignals.first?.contains("PATH") == true)
        XCTAssertTrue(missingCommand.suggestedNextAction?.fallbackNextSteps.first?.contains("command -v") == true)
        XCTAssertEqual(missingFile.diagnosticCategory, .missingFile)
        XCTAssertEqual(missingFile.diagnosticPriorityScore, 54)
        XCTAssertEqual(
            missingFile.diagnosticPriorityFactors,
            [.failedCommand, .failedSeverity, .missingFileCategory, .highConfidenceCategory]
        )
        XCTAssertEqual(missingFile.diagnosticCategoryEvidence, "cat: config.yml: No such file or directory")
        XCTAssertEqual(missingFile.diagnosticCategoryConfidence, .high)
        XCTAssertEqual(missingFile.suggestedNextCommand, "pwd && ls -la")
        XCTAssertEqual(missingFile.suggestedNextAction?.id, .inspectDirectory)
        XCTAssertEqual(missingFile.suggestedNextAction?.sourceCategory, .missingFile)
        XCTAssertEqual(missingFile.suggestedNextAction?.confidence, .high)
        XCTAssertEqual(missingFile.suggestedNextAction?.priorityScore, 54)
        XCTAssertEqual(missingFile.suggestedNextAction?.priorityFactors, missingFile.diagnosticPriorityFactors)
        XCTAssertTrue(missingFile.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(missingFile.suggestedNextAction?.actionScope, .workingDirectory)
        XCTAssertEqual(missingFile.suggestedNextAction?.expectedResultKind, .directoryListing)
        XCTAssertEqual(
            missingFile.suggestedNextAction?.expectedResultFields,
            [.workingDirectory, .visibleEntries, .fileMetadata]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.expectedResultSignals,
            [.workingDirectoryVisible, .directoryEntriesVisible]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultParsingHints,
            [.commandSequenceOutput, .directoryListingOutput]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultInterpretationHints,
            [.missingEntryConfirmsPathIssue, .caseMismatchMayMatter]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultDecisionHints,
            [.missingEntryRequiresRestoreGenerateOrReconfigure, .generatedPrerequisiteMayBeNeeded]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultCaveats,
            [.directorySnapshotMayBecomeStale, .generatedFilesMayAppearAfterSetup]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.sensitiveResultFields,
            [.workingDirectory, .visibleEntries, .fileMetadata]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultRedactionHints,
            [.workingDirectory, .directoryEntries, .fileMetadata]
        )
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultRefreshTriggers,
            [.workingDirectoryChanged, .filesystemChanged]
        )
        XCTAssertEqual(missingFile.suggestedNextAction?.resultPrivacyLevel, .sensitive)
        XCTAssertEqual(missingFile.suggestedNextAction?.resultSharingPolicy, .localOnly)
        XCTAssertEqual(missingFile.suggestedNextAction?.resultRetentionPolicy, .localSessionOnly)
        XCTAssertEqual(missingFile.suggestedNextAction?.title, "Inspect current directory")
        XCTAssertEqual(missingFile.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(missingFile.suggestedNextAction?.executionTarget, .currentWorkingDirectory)
        XCTAssertEqual(missingFile.suggestedNextAction?.resultValidityScope, .currentWorkingDirectory)
        XCTAssertEqual(missingFile.suggestedNextAction?.resultFreshnessPolicy, .liveSnapshot)
        XCTAssertEqual(missingFile.suggestedNextAction?.resultReuseKeyFields, [.workingDirectory, .filesystemState])
        XCTAssertEqual(missingFile.suggestedNextAction?.resultReusePolicy, .refreshBeforeUse)
        XCTAssertEqual(
            missingFile.suggestedNextAction?.resultReuseValidationChecks,
            [.refreshDynamicSnapshot, .matchWorkingDirectory, .matchObservedSignal]
        )
        XCTAssertEqual(missingFile.suggestedNextAction?.retryCondition, .fileOrDirectoryVerified)
        XCTAssertTrue(missingFile.suggestedNextAction?.preflightChecks.first?.contains("missing path") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.automationGuardrails.first?.contains("placeholder files") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.userDecisionPoints.first?.contains("restored") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.completionCriteria.first?.contains("expected path exists") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.expectedSignals.first?.contains("should contain the file") == true)
        XCTAssertTrue(missingFile.suggestedNextAction?.fallbackNextSteps.first?.contains("project tree") == true)
        XCTAssertEqual(gitFailure.diagnosticCategory, .git)
        XCTAssertEqual(gitFailure.diagnosticPriorityScore, 100)
        XCTAssertEqual(
            gitFailure.diagnosticPriorityFactors,
            [.failedCommand, .criticalSeverity, .gitCategory, .mediumConfidenceCategory]
        )
        XCTAssertEqual(gitFailure.diagnosticCategoryEvidence, "git pull")
        XCTAssertEqual(gitFailure.diagnosticCategoryConfidence, .medium)
        XCTAssertEqual(gitFailure.suggestedNextCommand, "git status --short --branch")
        XCTAssertEqual(gitFailure.suggestedNextAction?.id, .inspectGitState)
        XCTAssertEqual(gitFailure.suggestedNextAction?.sourceCategory, .git)
        XCTAssertEqual(gitFailure.suggestedNextAction?.confidence, .medium)
        XCTAssertEqual(gitFailure.suggestedNextAction?.priorityScore, 100)
        XCTAssertEqual(gitFailure.suggestedNextAction?.priorityFactors, gitFailure.diagnosticPriorityFactors)
        XCTAssertTrue(gitFailure.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(gitFailure.suggestedNextAction?.actionScope, .gitRepository)
        XCTAssertEqual(gitFailure.suggestedNextAction?.expectedResultKind, .gitStatus)
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.expectedResultFields,
            [.gitBranch, .gitUpstream, .gitDirtyState]
        )
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.expectedResultSignals,
            [.gitBranchVisible, .gitDirtyStateVisible]
        )
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultParsingHints,
            [.lineOrientedText, .gitStatusPorcelain]
        )
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultInterpretationHints,
            [.dirtyStateRequiresUserDecision, .upstreamRelationMayExplainFailure]
        )
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultDecisionHints,
            [.dirtyGitStateNeedsResolutionChoice, .cleanGitStateSuggestsRemoteOrAuthCheck]
        )
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultCaveats,
            [.gitStatusRequiresRepository, .cleanTreeDoesNotRuleOutRemoteFailure]
        )
        XCTAssertEqual(gitFailure.suggestedNextAction?.sensitiveResultFields, [.gitBranch, .gitUpstream])
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultRedactionHints, [.gitBranch, .gitUpstream])
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultRefreshTriggers, [.gitStateChanged])
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultPrivacyLevel, .contextual)
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultSharingPolicy, .redactBeforeSharing)
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultRetentionPolicy, .persistRedactedSummary)
        XCTAssertEqual(gitFailure.suggestedNextAction?.title, "Inspect Git state")
        XCTAssertEqual(gitFailure.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(gitFailure.suggestedNextAction?.executionTarget, .currentGitRepository)
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultValidityScope, .currentGitRepository)
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultFreshnessPolicy, .liveSnapshot)
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultReuseKeyFields,
            [.gitRepository, .gitBranch, .gitWorkingTreeState]
        )
        XCTAssertEqual(gitFailure.suggestedNextAction?.resultReusePolicy, .refreshBeforeUse)
        XCTAssertEqual(
            gitFailure.suggestedNextAction?.resultReuseValidationChecks,
            [.refreshDynamicSnapshot, .matchGitRepository, .matchGitState]
        )
        XCTAssertEqual(gitFailure.suggestedNextAction?.retryCondition, .gitStateReviewed)
        XCTAssertTrue(gitFailure.suggestedNextAction?.preflightChecks.first?.contains("intended repository") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.automationGuardrails.first?.contains("reset") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.userDecisionPoints.first?.contains("dirty") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.completionCriteria.first?.contains("working tree risk") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.expectedSignals.first?.contains("current branch") == true)
        XCTAssertTrue(gitFailure.suggestedNextAction?.fallbackNextSteps.first?.contains("remote") == true)
        XCTAssertEqual(genericFailure.diagnosticCategory, .generic)
        XCTAssertEqual(genericFailure.diagnosticPriorityScore, 45)
        XCTAssertEqual(
            genericFailure.diagnosticPriorityFactors,
            [.failedCommand, .failedSeverity, .genericCategory, .lowConfidenceCategory]
        )
        XCTAssertEqual(genericFailure.diagnosticCategoryEvidence, "ERROR validation failed")
        XCTAssertEqual(genericFailure.diagnosticCategoryConfidence, .low)
        XCTAssertEqual(genericFailure.suggestedNextAction?.id, .inspectLocalContext)
        XCTAssertEqual(genericFailure.suggestedNextAction?.sourceCategory, .generic)
        XCTAssertEqual(genericFailure.suggestedNextAction?.confidence, .low)
        XCTAssertEqual(genericFailure.suggestedNextAction?.priorityScore, 45)
        XCTAssertEqual(genericFailure.suggestedNextAction?.priorityFactors, genericFailure.diagnosticPriorityFactors)
        XCTAssertTrue(genericFailure.suggestedNextAction?.evidenceAnchors.contains(.diagnosticCategoryEvidence) == true)
        XCTAssertEqual(genericFailure.suggestedNextAction?.actionScope, .terminalSession)
        XCTAssertEqual(genericFailure.suggestedNextAction?.expectedResultKind, .contextSnapshot)
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.expectedResultFields,
            [.workingDirectory, .gitBranch, .gitUpstream, .gitDirtyState]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.expectedResultSignals,
            [.workingDirectoryVisible, .gitStateVisible]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultParsingHints,
            [.commandSequenceOutput, .optionalGitStatusOutput]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultInterpretationHints,
            [.gitOutputOptional, .contextSnapshotMayBePartial]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultDecisionHints,
            [.capturedContextShouldRecategorize, .genericFailureNeedsTargetedProbe]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultCaveats,
            [.contextSnapshotIsPartial, .genericFailureStillNeedsSpecificEvidence]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.sensitiveResultFields,
            [.workingDirectory, .gitBranch, .gitUpstream]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultRedactionHints,
            [.workingDirectory, .gitBranch, .gitUpstream]
        )
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultRefreshTriggers,
            [.workingDirectoryChanged, .gitStateChanged, .failureContextChanged]
        )
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultPrivacyLevel, .sensitive)
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultSharingPolicy, .localOnly)
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultRetentionPolicy, .localSessionOnly)
        XCTAssertEqual(genericFailure.suggestedNextAction?.title, "Inspect local context")
        XCTAssertEqual(genericFailure.suggestedNextAction?.executionMode, .stageOnly)
        XCTAssertEqual(genericFailure.suggestedNextAction?.executionTarget, .currentTerminalSession)
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultValidityScope, .currentTerminalSession)
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultFreshnessPolicy, .failureAttemptBound)
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultReuseKeyFields,
            [.terminalSession, .workingDirectory, .gitRepository, .failureFingerprint]
        )
        XCTAssertEqual(genericFailure.suggestedNextAction?.resultReusePolicy, .doNotReuseAcrossAttempts)
        XCTAssertEqual(
            genericFailure.suggestedNextAction?.resultReuseValidationChecks,
            [.matchFailureFingerprint, .matchWorkingDirectory, .doNotCrossAttemptBoundary]
        )
        XCTAssertEqual(genericFailure.suggestedNextAction?.retryCondition, .localContextCaptured)
        XCTAssertTrue(genericFailure.suggestedNextAction?.preflightChecks.first?.contains("enough output") == true)
        XCTAssertTrue(genericFailure.suggestedNextAction?.automationGuardrails.first?.contains("destructive fix") == true)
        XCTAssertTrue(genericFailure.suggestedNextAction?.userDecisionPoints.first?.contains("subsystem") == true)
        XCTAssertTrue(genericFailure.suggestedNextAction?.completionCriteria.first?.contains("recategorized") == true)
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

    private func runMuseTermCLIScript(
        _ scriptURL: URL,
        home: URL,
        arguments: [String]
    ) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [scriptURL.path] + arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "unknown CLI error"
            XCTFail("museterm CLI failed: \(message)")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func runMuseTermCLIRequestScript(
        _ scriptURL: URL,
        home: URL,
        arguments: [String],
        response: [String: Any]
    ) throws -> (output: [String: Any], request: [String: Any]) {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [scriptURL.path] + arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()

        let request = try answerNextToolRequest(home: home, response: response)

        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "unknown CLI error"
            XCTFail("museterm CLI request failed: \(message)")
        }
        let parsedOutput = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (output: parsedOutput, request: request)
    }

    private func runMuseTermMCPRequestWithToolResponse(
        _ scriptURL: URL,
        home: URL,
        request: [String: Any],
        response: [String: Any]
    ) throws -> (response: [String: Any], toolRequest: [String: Any]) {
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let header = "Content-Length: \(requestData.count)\r\n\r\n"
        var inputData = Data(header.utf8)
        inputData.append(requestData)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [scriptURL.path, "mcp"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        input.fileHandleForWriting.write(inputData)
        try input.fileHandleForWriting.close()

        let toolRequest = try answerNextToolRequest(home: home, response: response)
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "unknown MCP error"
            XCTFail("museterm MCP request failed: \(message)")
        }
        return (response: try decodeMCPResponse(data), toolRequest: toolRequest)
    }

    private func runMuseTermMCPRequest(
        _ scriptURL: URL,
        home: URL,
        request: [String: Any]
    ) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let header = "Content-Length: \(requestData.count)\r\n\r\n"
        var inputData = Data(header.utf8)
        inputData.append(requestData)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [scriptURL.path, "mcp"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        input.fileHandleForWriting.write(inputData)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "unknown MCP error"
            XCTFail("museterm MCP failed: \(message)")
        }
        return try decodeMCPResponse(data)
    }

    private func answerNextToolRequest(home: URL, response: [String: Any]) throws -> [String: Any] {
        let tools = home
            .appendingPathComponent("Library/Application Support/MuseTerm/Tools", isDirectory: true)
        let requests = tools.appendingPathComponent("requests", isDirectory: true)
        let responses = tools.appendingPathComponent("responses", isDirectory: true)
        let deadline = Date().addingTimeInterval(2)
        var requestURL: URL?

        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: requests,
                includingPropertiesForKeys: nil
            )) ?? []
            if let file = files.first(where: { $0.pathExtension == "json" }) {
                requestURL = file
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let resolvedRequestURL = try XCTUnwrap(requestURL, "MuseTerm CLI did not create a tool request")
        let requestData = try Data(contentsOf: resolvedRequestURL)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let requestID = try XCTUnwrap(request["id"] as? String)
        var resolvedResponse = response
        resolvedResponse["id"] = requestID
        let responseData = try JSONSerialization.data(withJSONObject: resolvedResponse)
        try responseData.write(to: responses.appendingPathComponent("\(requestID).json"))
        return request
    }

    private func decodeMCPResponse(_ data: Data) throws -> [String: Any] {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            XCTFail("MCP response missing header separator")
            return [:]
        }
        let body = Data(data[range.upperBound...])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func makeMuseTermCLITestFixture() throws -> (root: URL, scriptURL: URL) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("museterm-cli-tests-\(UUID().uuidString)", isDirectory: true)
        let tools = root
            .appendingPathComponent("Library/Application Support/MuseTerm/Tools", isDirectory: true)
        try manager.createDirectory(at: tools, withIntermediateDirectories: true)

        let scriptURL = root.appendingPathComponent("museterm")
        try MuseTermCLIInstaller.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let state: [String: Any] = [
            "schemaVersion": 1,
            "app": "MuseTerm",
            "version": "test",
            "snapshotSequence": 42,
            "selectedTabID": "tab-1",
            "tabs": [
                [
                    "id": "tab-1",
                    "index": 1,
                    "title": "project",
                    "isSelected": true,
                    "state": "running",
                    "screen": "screen-abcdef",
                    "history": "history-abcdef",
                    "commandDiagnostics": [
                        "schemaVersion": 1,
                        "failedCommandCount": 0
                    ],
                    "commandBlocks": [
                        [
                            "id": "cmd-1",
                            "command": "make test",
                            "outputCharacterCount": 10,
                            "outputTail": "abcdef"
                        ]
                    ]
                ]
            ]
        ]
        let stateData = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        try stateData.write(to: tools.appendingPathComponent("state.json"))

        return (root: root, scriptURL: scriptURL)
    }

}
