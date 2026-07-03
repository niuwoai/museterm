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

    func testLlamaServerConfigurationAllowsEmptyAPIKey() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .llamaServer
        preferences.aiModel = "local-model"
        preferences.aiBaseURL = " http://127.0.0.1:8080/v1 "

        let configuration = try AIExplainClient.Configuration(preferences: preferences)

        XCTAssertEqual(configuration.provider, .llamaServer)
        XCTAssertEqual(configuration.model, "local-model")
        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(configuration.apiKey, "")
    }

    func testSwitchingProviderReplacesBuiltInDefaultBaseURL() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .google
        preferences.aiBaseURL = AIProviderKind.google.defaultBaseURL
        preferences.aiModel = AIProviderKind.google.defaultModel

        preferences.aiProvider = .ollama

        XCTAssertEqual(preferences.aiBaseURL, AIProviderKind.ollama.defaultBaseURL)
        XCTAssertEqual(preferences.aiModel, AIProviderKind.ollama.defaultModel)
    }

    func testSwitchingProviderPreservesCustomBaseURL() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .google
        preferences.aiBaseURL = "https://ai-gateway.example.test/v1"
        preferences.aiModel = "team-default"

        preferences.aiProvider = .ollama

        XCTAssertEqual(preferences.aiBaseURL, "https://ai-gateway.example.test/v1")
        XCTAssertEqual(preferences.aiModel, "team-default")
    }

    func testLoadingPreferencesRepairsStaleBuiltInProviderDefaults() throws {
        let suiteName = "museterm.ai-client.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AIProviderKind.ollama.rawValue, forKey: "ai.provider")
        defaults.set(AIProviderKind.google.defaultBaseURL, forKey: "ai.baseURL")
        defaults.set(AIProviderKind.google.defaultModel, forKey: "ai.model")

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.aiProvider, .ollama)
        XCTAssertEqual(preferences.aiBaseURL, AIProviderKind.ollama.defaultBaseURL)
        XCTAssertEqual(preferences.aiModel, AIProviderKind.ollama.defaultModel)
    }

    private func isolatedPreferences() throws -> TerminalPreferences {
        let suiteName = "museterm.ai-client.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalPreferences(defaults: defaults)
    }
}
