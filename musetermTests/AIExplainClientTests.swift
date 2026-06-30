import XCTest
@testable import museterm

final class AIExplainClientTests: XCTestCase {
    func testConfigurationRequiresModelBeforeNetworkUse() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "   "
        preferences.aiBaseURL = "http://127.0.0.1:11434/v1"

        XCTAssertThrowsError(try AIExplainClient.Configuration(preferences: preferences)) { error in
            guard case AIExplainError.missingModel = error else {
                return XCTFail("Expected missingModel, got \(error)")
            }
        }
    }

    func testConfigurationRequiresBaseURLBeforeNetworkUse() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "qwen3"
        preferences.aiBaseURL = "   "

        XCTAssertThrowsError(try AIExplainClient.Configuration(preferences: preferences)) { error in
            guard case AIExplainError.missingBaseURL = error else {
                return XCTFail("Expected missingBaseURL, got \(error)")
            }
        }
    }

    func testOllamaConfigurationAllowsEmptyAPIKey() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "qwen3"
        preferences.aiBaseURL = " http://127.0.0.1:11434/v1 "

        let configuration = try AIExplainClient.Configuration(preferences: preferences)

        XCTAssertEqual(configuration.provider, .ollama)
        XCTAssertEqual(configuration.model, "qwen3")
        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(configuration.apiKey, "")
    }

    private func isolatedPreferences() throws -> TerminalPreferences {
        let suiteName = "museterm.ai-client.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalPreferences(defaults: defaults)
    }
}
