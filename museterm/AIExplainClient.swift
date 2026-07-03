import Foundation

struct AIExplainClient {
    struct Configuration {
        let provider: AIProviderKind
        let providerName: String
        let model: String
        let baseURL: String
        let apiKey: String

        init(preferences: TerminalPreferences) throws {
            provider = preferences.aiProvider
            providerName = preferences.aiDisplayProviderName
            model = preferences.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            baseURL = preferences.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKey = preferences.loadAIAPIKey()

            guard !model.isEmpty else {
                throw AIExplainError.missingModel
            }
            guard !baseURL.isEmpty else {
                throw AIExplainError.missingBaseURL
            }
            if !provider.isLocalProvider, apiKey.isEmpty {
                throw AIExplainError.missingAPIKey(providerName)
            }
        }
    }

    let configuration: Configuration

    func explain(
        contextText: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let prompt = prompt(for: contextText)
        switch configuration.provider {
        case .anthropic:
            return try await anthropicStream(prompt: prompt, onChunk: onChunk)
        case .google:
            return try await googleStream(prompt: prompt, onChunk: onChunk)
        case .azureOpenAI:
            return try await openAICompatibleStream(prompt: prompt, azure: true, onChunk: onChunk)
        case .openAI, .openRouter, .ollama, .llamaServer, .custom:
            return try await openAICompatibleStream(prompt: prompt, azure: false, onChunk: onChunk)
        }
    }

    private func prompt(for contextText: String) -> String {
        [
            L10n.string("ai_explain.prompt_header"),
            "",
            contextText
        ].joined(separator: "\n")
    }

    private func openAICompatibleStream(
        prompt: String,
        azure: Bool,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: try chatCompletionsURL(azure: azure))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if azure {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "api-key")
        } else if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try jsonData([
            "model": configuration.model,
            "temperature": 0.2,
            "stream": true,
            "messages": [
                [
                    "role": "system",
                    "content": L10n.string("ai_explain.system_prompt")
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ])

        return try await streamSSE(request, onChunk: onChunk) { data in
            let chunk = try JSONDecoder().decode(OpenAIChatStreamChunk.self, from: data)
            return chunk.choices
                .compactMap { $0.delta?.content }
                .joined()
        }
    }

    private func anthropicStream(
        prompt: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: try endpoint(path: "/v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try jsonData([
            "model": configuration.model,
            "max_tokens": 1000,
            "temperature": 0.2,
            "stream": true,
            "system": L10n.string("ai_explain.system_prompt"),
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ])

        return try await streamSSE(request, onChunk: onChunk) { data in
            let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            return event.delta?.text
        }
    }

    private func googleStream(
        prompt: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let encodedModel = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.model
        var components = URLComponents(
            url: try endpoint(path: "/models/\(encodedModel):streamGenerateContent"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "key", value: configuration.apiKey),
            URLQueryItem(name: "alt", value: "sse")
        ]
        guard let url = components?.url else {
            throw AIExplainError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonData([
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "text": "\(L10n.string("ai_explain.system_prompt"))\n\n\(prompt)"
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ])

        return try await streamSSE(request, onChunk: onChunk) { data in
            let response = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
            return response.candidates
                .flatMap { $0.content.parts }
                .compactMap(\.text)
                .joined()
        }
    }

    private func streamSSE(
        _ request: URLRequest,
        onChunk: @escaping @MainActor (String) -> Void,
        decodeDataLine: (Data) throws -> String?
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIExplainError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count >= 500 {
                    break
                }
            }
            throw AIExplainError.requestFailed(httpResponse.statusCode, body)
        }

        var result = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else {
                if payload == "[DONE]" {
                    break
                }
                continue
            }
            guard let data = payload.data(using: .utf8) else { continue }

            let chunk = try decodeDataLine(data) ?? ""
            guard !chunk.isEmpty else { continue }
            result += chunk
            await MainActor.run {
                onChunk(chunk)
            }
        }

        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIExplainError.emptyResponse
        }
        return result
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIExplainError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIExplainError.requestFailed(httpResponse.statusCode, apiErrorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIExplainError.decodeFailed
        }
    }

    private func chatCompletionsURL(azure: Bool) throws -> URL {
        let url = try endpoint(path: "/chat/completions")
        guard azure else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let existingItems = components?.queryItems ?? []
        if !existingItems.contains(where: { $0.name == "api-version" }) {
            components?.queryItems = existingItems + [
                URLQueryItem(name: "api-version", value: "2024-02-15-preview")
            ]
        }
        guard let finalURL = components?.url else {
            throw AIExplainError.invalidURL
        }
        return finalURL
    }

    private func endpoint(path: String) throws -> URL {
        let trimmedBase = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            throw AIExplainError.missingBaseURL
        }
        guard var components = URLComponents(string: trimmedBase) else {
            throw AIExplainError.invalidURL
        }
        let lowerBase = components.path.lowercased()
        let lowerPath = path.lowercased()
        if !lowerBase.hasSuffix(lowerPath) {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }
        guard let url = components.url else {
            throw AIExplainError.invalidURL
        }
        return url
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func apiErrorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return ""
        }
        return String(message.prefix(500))
    }
}

struct AIModelDiscovery {
    let provider: AIProviderKind
    let baseURL: String
    let apiKey: String

    func fetch() async throws -> [String] {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            throw AIExplainError.missingBaseURL
        }
        if !provider.isLocalProvider, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIExplainError.missingAPIKey(provider.name)
        }

        switch provider {
        case .google:
            return try await googleModels()
        case .anthropic:
            return try await anthropicModels()
        case .azureOpenAI:
            return []
        case .openAI, .openRouter, .ollama, .llamaServer, .custom:
            do {
                return try await openAICompatibleModels()
            } catch {
                guard provider == .ollama else { throw error }
                return try await ollamaNativeModels()
            }
        }
    }

    private func openAICompatibleModels() async throws -> [String] {
        var request = URLRequest(url: try endpoint(path: "/models"))
        request.httpMethod = "GET"
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let response: OpenAIModelsResponse = try await send(request)
        return uniqueSorted(response.data.map(\.id))
    }

    private func anthropicModels() async throws -> [String] {
        var request = URLRequest(url: try endpoint(path: "/v1/models"))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let response: OpenAIModelsResponse = try await send(request)
        return uniqueSorted(response.data.map(\.id))
    }

    private func googleModels() async throws -> [String] {
        var components = URLComponents(
            url: try endpoint(path: "/models"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            throw AIExplainError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response: GoogleModelsResponse = try await send(request)
        return uniqueSorted(
            response.models
                .filter { model in
                    let methods = model.supportedGenerationMethods ?? []
                    return methods.isEmpty || methods.contains("generateContent") || methods.contains("streamGenerateContent")
                }
                .map { model in
                    model.name.replacingOccurrences(of: "models/", with: "")
                }
        )
    }

    private func ollamaNativeModels() async throws -> [String] {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeBase = trimmedBase.hasSuffix("/v1")
            ? String(trimmedBase.dropLast(3))
            : trimmedBase
        let discovery = AIModelDiscovery(provider: provider, baseURL: nativeBase, apiKey: apiKey)
        var request = URLRequest(url: try discovery.endpoint(path: "/api/tags"))
        request.httpMethod = "GET"
        let response: OllamaTagsResponse = try await send(request)
        return uniqueSorted(response.models.map(\.name))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIExplainError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIExplainError.requestFailed(httpResponse.statusCode, apiErrorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIExplainError.decodeFailed
        }
    }

    private func endpoint(path: String) throws -> URL {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            throw AIExplainError.missingBaseURL
        }
        guard var components = URLComponents(string: trimmedBase) else {
            throw AIExplainError.invalidURL
        }
        let lowerBase = components.path.lowercased()
        let lowerPath = path.lowercased()
        if !lowerBase.hasSuffix(lowerPath) {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }
        guard let url = components.url else {
            throw AIExplainError.invalidURL
        }
        return url
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func apiErrorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return ""
        }
        return String(message.prefix(500))
    }
}

enum AIExplainError: LocalizedError {
    case missingModel
    case missingBaseURL
    case missingAPIKey(String)
    case invalidURL
    case invalidResponse
    case requestFailed(Int, String)
    case emptyResponse
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return L10n.string("ai_explain.error.missing_model")
        case .missingBaseURL:
            return L10n.string("ai_explain.error.missing_base_url")
        case .missingAPIKey(let providerName):
            return L10n.format("ai_explain.error.missing_api_key", providerName)
        case .invalidURL:
            return L10n.string("ai_explain.error.invalid_url")
        case .invalidResponse:
            return L10n.string("ai_explain.error.invalid_response")
        case .requestFailed(let statusCode, let message):
            if message.isEmpty {
                return L10n.format("ai_explain.error.request_failed", statusCode)
            }
            return L10n.format("ai_explain.error.request_failed_with_message", statusCode, message)
        case .emptyResponse:
            return L10n.string("ai_explain.error.empty_response")
        case .decodeFailed:
            return L10n.string("ai_explain.error.decode_failed")
        }
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta?
    }

    let choices: [Choice]
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct GoogleModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }

    let models: [Model]
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

private struct AnthropicMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let text: String?
    }

    let content: [ContentBlock]
}

private struct AnthropicStreamEvent: Decodable {
    struct Delta: Decodable {
        let text: String?
    }

    let delta: Delta?
}

private struct GeminiGenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]
        }

        let content: Content
    }

    let candidates: [Candidate]
}
