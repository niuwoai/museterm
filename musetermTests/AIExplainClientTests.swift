import XCTest
@testable import museterm

final class AIExplainClientTests: XCTestCase {
    func testSettingsWindowSessionSavesPendingAPIKeyBeforeClosing() throws {
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .someIM
        let session = SettingsWindowSession()
        session.aiAPIKeyDraft = "  pending-api-key  "

        XCTAssertTrue(session.savePendingAIAPIKey(preferences: preferences))
        XCTAssertEqual(session.aiAPIKeyDraft, "")
        XCTAssertEqual(preferences.loadAIAPIKey(), "pending-api-key")
        XCTAssertEqual(
            session.aiStatusMessage,
            L10n.string("settings.ai.api_key.save_success")
        )
    }

    func testLegacyAIKeychainEntryMigratesToDedicatedService() throws {
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .someIM
        let account = "ai-provider/someIM/api-key"
        XCTAssertTrue(MuseTermKeychain.save("legacy-api-key", account: account))

        XCTAssertEqual(preferences.loadAIAPIKey(), "legacy-api-key")
        XCTAssertEqual(MuseTermKeychain.load(account: account), "")
        XCTAssertEqual(preferences.loadAIAPIKey(), "legacy-api-key")
    }

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

    func testCustomConfigurationUsesSavedAPIKey() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .custom
        preferences.aiCustomProviderName = "some.im"
        preferences.aiModel = "deepseek-v4-flash"
        preferences.aiBaseURL = "https://api.example.test/v1"

        XCTAssertTrue(preferences.saveAIAPIKey("  test-api-key  "))

        let configuration = try AIExplainClient.Configuration(preferences: preferences)

        XCTAssertEqual(configuration.provider, .custom)
        XCTAssertEqual(configuration.providerName, "some.im")
        XCTAssertEqual(configuration.apiKey, "test-api-key")
    }

    func testSomeIMUsesChinaNodeByDefaultAndSavedAPIKey() throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .someIM

        XCTAssertEqual(preferences.aiBaseURL, "https://api.niuwoai.com/v1")
        XCTAssertEqual(preferences.aiModel, AIProviderKind.someIM.defaultModel)
        XCTAssertTrue(preferences.saveAIAPIKey("test-api-key"))

        let configuration = try AIExplainClient.Configuration(preferences: preferences)

        XCTAssertEqual(configuration.provider, .someIM)
        XCTAssertEqual(configuration.providerName, "some.im")
        XCTAssertEqual(configuration.baseURL, "https://api.niuwoai.com/v1")
        XCTAssertEqual(configuration.apiKey, "test-api-key")
    }

    func testSomeIMCanKeepGlobalNodeSelectionAfterReload() throws {
        let suiteName = "museterm.ai-client.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AIProviderKind.someIM.rawValue, forKey: "ai.provider")
        defaults.set("https://some.im/v1", forKey: "ai.baseURL")
        defaults.set(AIProviderKind.someIM.defaultModel, forKey: "ai.model")

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.aiProvider, .someIM)
        XCTAssertEqual(preferences.aiBaseURL, "https://some.im/v1")
        XCTAssertEqual(preferences.aiModel, AIProviderKind.someIM.defaultModel)
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

    func testComposerChoiceOverridesTheSavedProviderAndModel() async throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "llama3.1"

        let configuration = try await AIExplainClient.Configuration.resolving(
            preferences: preferences,
            choice: AICommandModelChoice(provider: .magpie, model: "magpie-fast")
        )

        XCTAssertEqual(configuration.provider, .magpie)
        XCTAssertEqual(configuration.model, "magpie-fast")
        XCTAssertEqual(configuration.baseURL, AIProviderKind.magpie.defaultBaseURL)
        XCTAssertEqual(configuration.apiKey, AIProviderKind.magpieLocalGatewayAPIKey)
        XCTAssertEqual(preferences.aiProvider, .ollama)
        XCTAssertEqual(preferences.aiModel, "llama3.1")
    }

    func testComposerChoiceUsesTheSelectedProviderKey() async throws {
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .someIM
        XCTAssertTrue(preferences.saveAIAPIKey("saved-provider-key"))
        preferences.aiProvider = .google
        XCTAssertTrue(preferences.saveAIAPIKey("selected-provider-key"))
        preferences.aiProvider = .someIM

        let configuration = try await AIExplainClient.Configuration.resolving(
            preferences: preferences,
            choice: AICommandModelChoice(provider: .google, model: "gemini-2.5-pro")
        )

        XCTAssertEqual(configuration.provider, .google)
        XCTAssertEqual(configuration.apiKey, "selected-provider-key")
        XCTAssertEqual(preferences.aiProvider, .someIM)
        XCTAssertEqual(preferences.loadAIAPIKey(), "saved-provider-key")
    }

    func testComposerChoiceDoesNotBorrowAnotherProvidersKey() async throws {
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .someIM
        XCTAssertTrue(preferences.saveAIAPIKey("saved-provider-key"))

        do {
            _ = try await AIExplainClient.Configuration.resolving(
                preferences: preferences,
                choice: AICommandModelChoice(provider: .anthropic, model: "test-model")
            )
            XCTFail("Expected a missing key for the selected provider")
        } catch let error as AIExplainError {
            guard case .missingAPIKey = error else {
                return XCTFail("Expected missingAPIKey, got \(error)")
            }
        }
    }

    func testComposerChoiceKeepsTheSavedBaseURLWhenTheProviderMatches() async throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "llama3.1"
        preferences.aiBaseURL = "http://127.0.0.1:11435/v1"

        let configuration = try await AIExplainClient.Configuration.resolving(
            preferences: preferences,
            choice: AICommandModelChoice(provider: .ollama, model: "qwen2.5")
        )

        XCTAssertEqual(configuration.provider, .ollama)
        XCTAssertEqual(configuration.model, "qwen2.5")
        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:11435/v1")
    }

    func testComposerChoiceWithoutAModelFails() async throws {
        let preferences = try isolatedPreferences()
        preferences.aiProvider = .ollama
        preferences.aiModel = "llama3.1"

        do {
            _ = try await AIExplainClient.Configuration.resolving(
                preferences: preferences,
                choice: AICommandModelChoice(provider: .magpie, model: "  ")
            )
            XCTFail("Expected a missing model to be rejected")
        } catch let error as AIExplainError {
            guard case .missingModel = error else {
                return XCTFail("Expected missingModel, got \(error)")
            }
        }
    }

    private func isolatedPreferences() throws -> TerminalPreferences {
        let suiteName = "museterm.ai-client.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalPreferences(defaults: defaults)
    }
}
