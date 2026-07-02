import XCTest
@testable import museterm

final class TerminalSafetyInputAnalyzerTests: XCTestCase {
    func testMultilinePasteRequiresTwoNonEmptyLines() {
        XCTAssertFalse(SafetyInputAnalyzer.isMultilinePaste("echo ok\n"))
        XCTAssertFalse(SafetyInputAnalyzer.isMultilinePaste("\n\n"))
        XCTAssertTrue(SafetyInputAnalyzer.isMultilinePaste("echo one\n  \necho two\n"))
        XCTAssertEqual(SafetyInputAnalyzer.nonEmptyLineCount(in: "a\n \nb\nc"), 3)
    }

    func testBuiltInDangerousRulesMatchCommonHighRiskCommands() {
        XCTAssertNotNil(SafetyInputAnalyzer.dangerousRule(for: "sudo rm -rf /tmp/build", customRulesText: ""))
        XCTAssertNotNil(SafetyInputAnalyzer.dangerousRule(for: "kubectl delete deployment api", customRulesText: ""))
        XCTAssertNotNil(SafetyInputAnalyzer.dangerousRule(for: "git reset --hard HEAD~1", customRulesText: ""))
        XCTAssertNil(SafetyInputAnalyzer.dangerousRule(for: "git status --short", customRulesText: ""))
    }

    func testCustomDangerousRulesSupportPlainTextAndRegex() {
        let customRules = """
        # ignored
        deploy prod
        regex:^vault\\s+write
        regex:[
        """

        XCTAssertNotNil(SafetyInputAnalyzer.dangerousRule(for: "scripts/deploy prod", customRulesText: customRules))
        XCTAssertNotNil(SafetyInputAnalyzer.dangerousRule(for: "VAULT write secret/app token=abc", customRulesText: customRules))
        XCTAssertNil(SafetyInputAnalyzer.dangerousRule(for: "deploy staging", customRulesText: customRules))
    }

    func testPendingCommandCandidateWaitsForNewline() {
        XCTAssertNil(
            SafetyInputAnalyzer.pendingCommandCandidate(
                existingBytes: Array("sudo ".utf8),
                appending: Array("rm -rf /tmp/build".utf8)
            )
        )
    }

    func testPendingCommandCandidateCombinesExistingInputUntilNewline() {
        let command = SafetyInputAnalyzer.pendingCommandCandidate(
            existingBytes: Array("sudo rm -".utf8),
            appending: Array("rf /tmp/build\rignored".utf8)
        )

        XCTAssertEqual(command, "sudo rm -rf /tmp/build")
    }

    func testUpdatedPendingInputBytesHandlesBackspace() {
        let bytes = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: Array("git statuz".utf8),
            appending: [0x7F] + Array("s".utf8),
            echoEnabled: true,
            maxBytes: 256
        )

        XCTAssertEqual(String(bytes: bytes, encoding: .utf8), "git status")
    }

    func testUpdatedPendingInputBytesClearsOnControlCAndNewline() {
        let interrupted = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: Array("rm -rf /tmp".utf8),
            appending: [0x03],
            echoEnabled: true,
            maxBytes: 256
        )
        let submitted = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: Array("git status".utf8),
            appending: [0x0D],
            echoEnabled: true,
            maxBytes: 256
        )

        XCTAssertTrue(interrupted.isEmpty)
        XCTAssertTrue(submitted.isEmpty)
    }

    func testUpdatedPendingInputBytesClearsWhenEchoIsDisabled() {
        let bytes = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: Array("secret".utf8),
            appending: Array("more".utf8),
            echoEnabled: false,
            maxBytes: 256
        )

        XCTAssertTrue(bytes.isEmpty)
    }

    func testUpdatedPendingInputBytesKeepsMostRecentBytesWithinLimit() {
        let bytes = SafetyInputAnalyzer.updatedPendingInputBytes(
            existingBytes: Array("abcdef".utf8),
            appending: Array("ghi".utf8),
            echoEnabled: true,
            maxBytes: 5
        )

        XCTAssertEqual(String(bytes: bytes, encoding: .utf8), "efghi")
    }

    func testPreviewTruncatesLongText() {
        let text = String(repeating: "x", count: 4_010)
        let preview = SafetyInputAnalyzer.preview(text)

        XCTAssertEqual(preview.count, 4_004)
        XCTAssertTrue(preview.hasSuffix("\n..."))
    }

    func testMultilinePasteConfirmationMessageIncludesCountAndReason() {
        let message = SafetyInputAnalyzer.multilinePasteConfirmationMessage(for: "echo one\n\necho two\n")

        XCTAssertTrue(message.contains(L10n.format("safety.multiline.message", 2)))
        XCTAssertTrue(message.contains(L10n.string("safety.multiline.reason")))
        XCTAssertTrue(message.contains("\n\n"))
    }

    func testMuseTermRemoteIntegrationPasteUsesSpecificConfirmationCopy() throws {
        let script = try XCTUnwrap(
            RemoteShellIntegration.startupCommands(for: SSHConnectionProfile(host: "example.test")).first
        )

        XCTAssertTrue(SafetyInputAnalyzer.isMuseTermRemoteShellIntegrationBootstrap(script))
        XCTAssertEqual(
            SafetyInputAnalyzer.multilinePasteConfirmationTitle(for: script),
            L10n.string("safety.multiline.remote_integration.title")
        )
        XCTAssertEqual(
            SafetyInputAnalyzer.multilinePastePrimaryActionTitle(for: script),
            L10n.string("safety.multiline.remote_integration.action")
        )

        let message = SafetyInputAnalyzer.multilinePasteConfirmationMessage(for: script)
        XCTAssertTrue(message.contains(L10n.string("safety.multiline.remote_integration.message")))
        XCTAssertTrue(message.contains(L10n.string("safety.multiline.remote_integration.scope")))
    }

    func testOrdinaryMultilinePasteWithMarkerLikeTextDoesNotUseRemoteIntegrationCopy() {
        let text = "echo MuseTerm;start=debug\nprintf done\n"

        XCTAssertFalse(SafetyInputAnalyzer.isMuseTermRemoteShellIntegrationBootstrap(text))
        XCTAssertEqual(
            SafetyInputAnalyzer.multilinePasteConfirmationTitle(for: text),
            L10n.string("safety.multiline.title")
        )
        XCTAssertEqual(
            SafetyInputAnalyzer.multilinePastePrimaryActionTitle(for: text),
            L10n.string("safety.action.send")
        )
    }

}
