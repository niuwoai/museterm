import XCTest
@testable import museterm

final class RunbookMarkdownExporterTests: XCTestCase {
    func testReplayScriptParameterizesPathsAndWrapsConfirmedSteps() {
        let block = commandBlock(
            command: "cd /Users/tester/project && swift test",
            workingDirectory: "/Users/tester/project"
        )

        let script = RunbookMarkdownExporter.replayScript(
            blocks: [block],
            redactSensitiveData: true,
            parameterizePaths: true,
            confirmEachStep: true,
            variableOverrides: RunbookReplayVariableOverrides(
                homePath: "/Users/tester",
                workingDirectory: "/Users/tester/project"
            )
        )

        XCTAssertTrue(script.contains("set -euo pipefail"))
        XCTAssertTrue(script.contains("RUNBOOK_HOME=${RUNBOOK_HOME:-'/Users/tester'}"))
        XCTAssertTrue(script.contains("RUNBOOK_WORKDIR=${RUNBOOK_WORKDIR:-'/Users/tester/project'}"))
        XCTAssertTrue(script.contains("run_step() {"))
        XCTAssertTrue(script.contains(#"cd "${RUNBOOK_WORKDIR}" && swift test"#))
        XCTAssertFalse(script.contains("run_step 'cd /Users/tester/project && swift test'"))
    }

    func testReplayScriptRedactsSensitiveCommandArguments() {
        let secret = "secret-token-123"
        let block = commandBlock(
            command: "curl --token \(secret) https://api.example.com/deploy",
            workingDirectory: "/tmp/project"
        )

        let script = RunbookMarkdownExporter.replayScript(
            blocks: [block],
            redactSensitiveData: true,
            parameterizePaths: false,
            confirmEachStep: false,
            variableOverrides: RunbookReplayVariableOverrides(homePath: "", workingDirectory: "")
        )

        XCTAssertTrue(script.contains("curl --token [REDACTED] https://api.example.com/deploy"))
        XCTAssertFalse(script.contains(secret))
    }

    func testReplayScriptSkipsBlankCommands() {
        let script = RunbookMarkdownExporter.replayScript(
            blocks: [
                commandBlock(command: "   ", workingDirectory: nil),
                commandBlock(command: "\n", workingDirectory: nil)
            ],
            redactSensitiveData: true,
            parameterizePaths: true,
            confirmEachStep: true,
            variableOverrides: RunbookReplayVariableOverrides(homePath: "", workingDirectory: "")
        )

        XCTAssertEqual(script, "")
    }

    private func commandBlock(command: String, workingDirectory: String?) -> TerminalCommandBlock {
        TerminalCommandBlock(
            id: UUID(),
            command: command,
            workingDirectory: workingDirectory,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: 0,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .userInput,
            completionSource: .shellIntegration
        )
    }
}
