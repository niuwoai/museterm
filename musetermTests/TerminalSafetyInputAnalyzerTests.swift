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
}
