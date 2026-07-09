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

    func testSomeIMBrowserLoginUsesSomeIMOriginAndWillDeepDeviceCode() throws {
        let request = try SomeIMBrowserLoginConnector.makeRequest()
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "some.im")
        XCTAssertEqual(components.path, "/customer/login")
        XCTAssertEqual(query["client_id"], "willdeep")
        XCTAssertEqual(query["willdeep_device_code"], request.code)
        XCTAssertTrue(request.code.range(of: #"^WD-[A-Z2-9]{4}-[A-Z2-9]{4}$"#, options: .regularExpression) != nil)
        XCTAssertEqual(query["willdeep_pair_token"], request.pairToken)
        XCTAssertEqual(request.pairToken.count, 64)
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
