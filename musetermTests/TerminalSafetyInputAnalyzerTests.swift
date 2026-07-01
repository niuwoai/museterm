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

    func testShellArgumentEscaperQuotesPlainSelectionForPathUse() {
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "hello world"),
            "'hello world'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "weird'name"),
            "'weird'\\''name'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "-starts-with-dash"),
            "./'-starts-with-dash'"
        )
    }

    func testShellArgumentEscaperPreservesExistingShellEscapedSelection() {
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "''$'\\344\\270\\213'"),
            "''$'\\344\\270\\213'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "file\\ name"),
            "file\\ name"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.typedArgument(fromTerminalSelection: "file name"),
            " 'file name'"
        )
    }

    func testShellArgumentEscaperRejectsEmptyOrMultilineSelection() {
        XCTAssertNil(TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "  "))
        XCTAssertNil(TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "one\ntwo"))
    }
}
