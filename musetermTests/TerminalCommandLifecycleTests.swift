import XCTest
@testable import museterm

@MainActor
final class TerminalCommandLifecycleTests: XCTestCase {
    func testCommandBlockClassifiesBoundaryConfidenceAndLifecycleState() throws {
        let high = TerminalCommandBlock(
            id: UUID(),
            command: "swift test",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: 0,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .shellIntegration
        )
        let mediumFromProcessExit = TerminalCommandBlock(
            id: UUID(),
            command: "swift build",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: 0,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .processExit
        )
        let low = TerminalCommandBlock(
            id: UUID(),
            command: "tail -f app.log",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            exitCode: nil,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: true,
            commandStartSource: .userInput,
            completionSource: nil
        )
        let interrupted = TerminalCommandBlock(
            id: UUID(),
            command: "sleep 60",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: 130,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .userInterrupt
        )
        let superseded = TerminalCommandBlock(
            id: UUID(),
            command: "python server.py",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: nil,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .userInput,
            completionSource: .superseded
        )
        let completedUnknown = TerminalCommandBlock(
            id: UUID(),
            command: "custom-tool",
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: nil,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .unknown,
            completionSource: .unknown
        )

        XCTAssertEqual(high.commandLifecycleState, .succeeded)
        XCTAssertEqual(high.commandBoundaryConfidence, .high)
        XCTAssertEqual(high.commandBoundaryReasons, [.shellIntegrationStart, .shellIntegrationCompletion])
        XCTAssertEqual(mediumFromProcessExit.commandLifecycleState, .succeeded)
        XCTAssertEqual(mediumFromProcessExit.commandBoundaryConfidence, .medium)
        XCTAssertEqual(mediumFromProcessExit.commandBoundaryReasons, [.shellIntegrationStart, .processExitCompletion])
        XCTAssertEqual(low.commandLifecycleState, .running)
        XCTAssertEqual(low.commandBoundaryConfidence, .low)
        XCTAssertEqual(low.commandBoundaryReasons, [.userInputStart, .commandStillRunning])
        XCTAssertEqual(interrupted.commandLifecycleState, .interrupted)
        XCTAssertEqual(superseded.commandLifecycleState, .superseded)
        XCTAssertEqual(completedUnknown.commandLifecycleState, .completedUnknownStatus)
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
        XCTAssertEqual(block.commandLifecycleState, .running)
        XCTAssertEqual(block.commandBoundaryConfidence, .low)
        XCTAssertEqual(block.commandBoundaryReasons, [.shellIntegrationStart, .commandStillRunning])
        XCTAssertTrue(block.searchableText.contains("shellIntegration"))
        XCTAssertTrue(block.aiContextText.contains("Command source: shellIntegration"))
    }

    func testTerminalSessionNormalizesDetectedShellName() {
        let tab = TerminalSession(sequence: 1)

        tab.updateShellName("/usr/local/bin/fish\n")
        XCTAssertEqual(tab.shellName, "fish")

        tab.updateShellName("-bash")
        XCTAssertEqual(tab.shellName, "bash")

        tab.updateShellName("'zsh'")
        XCTAssertEqual(tab.shellName, "zsh")
    }

}
