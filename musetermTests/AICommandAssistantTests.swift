import AppKit
import XCTest
@testable import museterm

final class AICommandAssistantTests: XCTestCase {
    func testComposerInputExpandsToAtMostFiveLines() {
        XCTAssertEqual(AICommandComposerLayout.maximumInputLines, 5)
        XCTAssertEqual(AICommandComposerLayout.minimumBarHeight, 46)
    }

    func testComposerUsesCompactSpacingForContextRow() {
        XCTAssertEqual(AICommandComposerLayout.contextRowSpacing, 4)
        XCTAssertEqual(AICommandComposerLayout.bottomRowSpacing, 10)
    }

    func testModelListFollowsTheSelectedProvider() {
        let ollama = AICommandModelChoice(provider: .ollama, model: "llama3.1")
        XCTAssertEqual(ollama.models(discovered: ["qwen2.5", "llama3.1"]), ["qwen2.5", "llama3.1"])

        let switched = ollama.switching(to: .magpie)
        XCTAssertEqual(switched.provider, .magpie)
        XCTAssertEqual(switched.model, "")
        XCTAssertEqual(switched.models(discovered: ["magpie-fast"]), ["magpie-fast"])
        XCTAssertFalse(switched.models(discovered: ["magpie-fast"]).contains("llama3.1"))
    }

    func testModelListKeepsTheCurrentChoiceAheadOfDiscovery() {
        let choice = AICommandModelChoice(provider: .openAI, model: "gpt-4.1")
        XCTAssertEqual(choice.models(discovered: []), ["gpt-4.1"])
        XCTAssertEqual(choice.models(discovered: ["gpt-4.1", "gpt-4.1-mini"]), ["gpt-4.1", "gpt-4.1-mini"])
    }

    func testPreferredChoiceFollowsSavedSettings() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.aiProvider = .ollama
        preferences.aiModel = "qwen2.5"

        let choice = AICommandModelChoice.preferred(preferences: preferences)
        XCTAssertEqual(choice.provider, .ollama)
        XCTAssertEqual(choice.model, "qwen2.5")
    }

    @MainActor
    func testSelectingProviderInTheComposerSwapsTheModelList() {
        let model = AICommandAssistantModel()
        model.modelChoice = AICommandModelChoice(provider: .ollama, model: "llama3.1")

        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TerminalPreferences(defaults: defaults)

        model.selectProvider(.magpie, preferences: preferences)
        XCTAssertEqual(model.modelChoice.provider, .magpie)
        XCTAssertNotEqual(model.modelChoice.model, "llama3.1")
        XCTAssertTrue(model.discoveredModels.isEmpty)

        model.selectModel("magpie-fast")
        XCTAssertEqual(model.modelChoice.model, "magpie-fast")

        model.selectProvider(.magpie, preferences: preferences)
        XCTAssertEqual(model.modelChoice.model, "magpie-fast")
    }

    func testComposerKeyboardActionsDistinguishSubmitAndNewline() {
        XCTAssertEqual(
            AICommandComposerKeyResolver.action(keyCode: 36, modifierFlags: []),
            .submit
        )
        XCTAssertEqual(
            AICommandComposerKeyResolver.action(keyCode: 36, modifierFlags: [.shift]),
            .insertNewline
        )
        XCTAssertEqual(
            AICommandComposerKeyResolver.action(keyCode: 76, modifierFlags: []),
            .submit
        )
    }

    func testComposerKeyboardActionsPassThroughOtherShortcuts() {
        XCTAssertEqual(
            AICommandComposerKeyResolver.action(keyCode: 36, modifierFlags: [.command]),
            .passthrough
        )
        XCTAssertEqual(
            AICommandComposerKeyResolver.action(keyCode: 0, modifierFlags: [.shift]),
            .passthrough
        )
    }

    func testDoubleControlTriggersAfterTwoIsolatedTaps() {
        var detector = DoubleModifierTapDetector()

        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.00,
            activation: .doubleControl
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [],
            timestamp: 1.05,
            activation: .doubleControl
        ))
        XCTAssertTrue(detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.20,
            activation: .doubleControl
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [],
            timestamp: 1.25,
            activation: .doubleControl
        ))
    }

    func testDoubleModifierTapRequiresAnUninterruptedSequence() {
        var detector = DoubleModifierTapDetector()

        _ = detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.00,
            activation: .doubleControl
        )
        _ = detector.handleFlagsChanged(
            flags: [],
            timestamp: 1.05,
            activation: .doubleControl
        )
        detector.registerKeyDown()

        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.20,
            activation: .doubleControl
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [],
            timestamp: 1.25,
            activation: .doubleControl
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [.control, .shift],
            timestamp: 1.30,
            activation: .doubleControl
        ))
    }

    func testDisabledActivationNeverTriggers() {
        var detector = DoubleModifierTapDetector()

        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.00,
            activation: .disabled
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [],
            timestamp: 1.05,
            activation: .disabled
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            flags: [.control],
            timestamp: 1.10,
            activation: .disabled
        ))
    }

    func testSuggestionParserExtractsJSONAndAppliesLocalRiskAnalysis() throws {
        let response = """
        Here are suggestions:
        {"candidates":[
          {"command":"journalctl -u nginx -n 100 --no-pager","explanation":"Read recent service logs."},
          {"command":"rm -r /tmp/build","explanation":"Remove the build directory."}
        ]}
        """

        let suggestions = try AICommandResponseParser.parse(response)

        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0].riskProfile.level, .readOnly)
        XCTAssertEqual(suggestions[1].riskProfile.level, .mutating)
    }

    func testSuggestionParserRejectsMultilineCommands() {
        let response = """
        {"candidates":[{"command":"pwd\\nwhoami","explanation":"Two commands."}]}
        """

        XCTAssertThrowsError(try AICommandResponseParser.parse(response)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                AICommandAssistantError.invalidSuggestions.localizedDescription
            )
        }
    }

    @MainActor
    func testClosingAssistantEndsTheCurrentSession() {
        let session = TerminalSession(sequence: 1)
        let model = AICommandAssistantModel()

        model.present(for: session)
        XCTAssertEqual(model.phase, .composing)
        XCTAssertTrue(model.isActive)

        model.dismiss()
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.notice, .ended)
    }

    func testAICommandActivationPersistsAndRestoresDefault() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.aiCommandActivation, .doubleControl)

        preferences.aiCommandActivation = .doubleShift
        XCTAssertEqual(
            TerminalPreferences(defaults: defaults).aiCommandActivation,
            .doubleShift
        )

        preferences.restoreDefaultAppShortcuts()
        XCTAssertEqual(preferences.aiCommandActivation, .doubleControl)
    }
}
