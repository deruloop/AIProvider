//
//  GeminiProvider.swift
//  VoltaSDK
//
//  Developer-key provider for Google's Gemini API (generateContent).
//  Same shape as the other cloud providers: typed errors, Codable DTOs,
//  history → the vendor's native contents format (D12).
//
//  API notes:
//   - Auth is the `x-goog-api-key` header.
//   - History roles are "user" and "model" (not "assistant").
//   - Instructions go in the top-level `systemInstruction`.
//   - Errors use {error: {code, message, status}}; an invalid key surfaces
//     as a 400 INVALID_ARGUMENT, not a 401.
//

import Foundation

public struct GeminiProvider: ModelProvider {

    public let identifier = ProviderIdentifier.gemini
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let temperature: Double
    private let baseURL: URL
    private let urlSession: URLSession
    private let explicitContextSize: Int?

    public init(
        apiKey: String,
        model: String = CloudVendor.gemini.defaultModel,
        maxTokens: Int = 1000,
        temperature: Double = 0.3,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        urlSession: URLSession = .shared,
        contextSize: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.explicitContextSize = contextSize
    }

    // MARK: Token awareness (D13) — honest estimates

    public var contextSize: Int? {
        if let explicitContextSize { return explicitContextSize }
        return Self.knownContextSize(forModel: model)
    }

    static func knownContextSize(forModel model: String) -> Int? {
        if model.hasPrefix("gemini-1.5-pro") { return 2_097_152 }
        if model.hasPrefix("gemini-") { return 1_048_576 }
        return nil
    }

    /// ESTIMATE (~4 characters/token), like the other cloud providers.
    public func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? {
        var characters = prompt.count + (instructions?.count ?? 0)
        for turn in history { characters += turn.text.count }
        return (characters + 3) / 4
    }

    public func availability() async -> ProviderAvailability {
        apiKey.isEmpty
            ? .unavailable(reason: "API key not configured")
            : .available
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        // App-supplied history (D12) → user/model turns → current prompt.
        var contents: [GenerateRequest.Content] = []
        for turn in history {
            contents.append(.init(
                role: turn.role == .user ? "user" : "model",
                parts: [.init(text: turn.text)]
            ))
        }
        contents.append(.init(role: "user", parts: [.init(text: prompt)]))

        let body = GenerateRequest(
            systemInstruction: (instructions?.isEmpty == false)
                ? .init(role: nil, parts: [.init(text: instructions!)])
                : nil,
            contents: contents,
            generationConfig: .init(
                temperature: temperature,
                maxOutputTokens: maxTokens
            )
        )

        // Credential detection, D15-style: a Google API key always starts with
        // "AIza" and speaks the Developer API (generativelanguage). Anything
        // else is an OAuth access token (user-account path, "ya29.…") — and
        // OAuth tokens are a DIFFERENT TRANSPORT, not just a different header:
        // generativelanguage rejects them with ACCESS_TOKEN_SCOPE_INSUFFICIENT
        // regardless of granted scopes (observed live). The endpoint that
        // accepts user tokens (cloud-platform scope) is the Code Assist front
        // end, cloudcode-pa.googleapis.com — the same models behind Google's
        // own Gemini CLI sign-in, with its {model, project, request} envelope.
        if apiKey.hasPrefix("AIza") {
            return try await developerAPIRespond(body)
        }
        return try await codeAssistRespond(body)
    }

    // MARK: Developer API transport (API key)

    private func developerAPIRespond(_ body: GenerateRequest) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("models/\(model):generateContent")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.encoding("Request encoding failed: \(error.localizedDescription)")
        }

        let data = try await send(request)
        return try Self.extractText(try Self.decode(GenerateResponse.self, from: data))
    }

    // MARK: Code Assist transport (OAuth user token)
    //
    // The endpoint behind Google's own Gemini CLI "Sign in with Google": it
    // accepts cloud-platform user tokens and fronts the same Gemini models
    // (free tier included). Protocol from the open-source Gemini CLI:
    // a loadCodeAssist/onboardUser handshake yields the managed project, then
    // generateContent takes {"model", "project", "request"} and returns
    // {"response": <standard GenerateContentResponse>}.

    private static let codeAssistBase = URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!

    private func codeAssistRespond(_ body: GenerateRequest) async throws -> String {
        let project = try await codeAssistProject()
        var request = makeCodeAssistRequest(action: "generateContent")
        do {
            request.httpBody = try JSONEncoder().encode(
                CodeAssistGenerateRequest(model: model, project: project, request: body)
            )
        } catch {
            throw ProviderError.encoding("Request encoding failed: \(error.localizedDescription)")
        }
        let data = try await send(request)
        let envelope = try Self.decode(CodeAssistGenerateResponse.self, from: data)
        guard let inner = envelope.response else { throw ProviderError.emptyResponse }
        return try Self.extractText(inner)
    }

    /// Resolves the user's managed Code Assist project: ask (`loadCodeAssist`),
    /// and if the account was never onboarded, run the free-tier onboarding
    /// once and ask again.
    private func codeAssistProject() async throws -> String {
        if let project = try await loadCodeAssistProject() { return project }

        var onboard = makeCodeAssistRequest(action: "onboardUser")
        onboard.httpBody = try? JSONEncoder().encode(
            OnboardUserRequest(tierId: "free-tier", metadata: .init())
        )
        let lro = try? Self.decode(OnboardLRO.self, from: try await send(onboard))
        if let project = lro?.response?.cloudaicompanionProject?.id { return project }

        // Onboarding is a long-running operation; give it a beat, ask again.
        try? await Task.sleep(for: .seconds(2))
        if let project = try await loadCodeAssistProject() { return project }

        throw ProviderError.api(
            message: "Google Code Assist did not return a project for this account — the OAuth token is valid, but the account isn't onboarded to the Gemini free tier yet.",
            code: "code-assist-onboarding"
        )
    }

    private func loadCodeAssistProject() async throws -> String? {
        var request = makeCodeAssistRequest(action: "loadCodeAssist")
        request.httpBody = try? JSONEncoder().encode(LoadCodeAssistRequest(metadata: .init()))
        let data = try await send(request)
        return (try? Self.decode(LoadCodeAssistResponse.self, from: data))?.cloudaicompanionProject
    }

    private func makeCodeAssistRequest(action: String) -> URLRequest {
        // v1internal endpoints use the ":action" form on the base path.
        var request = URLRequest(
            url: URL(string: Self.codeAssistBase.absoluteString + ":" + action)!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Shared transport plumbing

    /// Sends the request and maps HTTP failures onto `ProviderError` —
    /// identical semantics for both transports.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw ProviderError.cancelled }
            throw ProviderError.network(code: urlError.errorCode)
        } catch {
            throw ProviderError.network(code: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(code: -1)
        }

        switch http.statusCode {
        case 200...299:
            guard !data.isEmpty else { throw ProviderError.emptyResponse }
            return data
        case 401, 403:
            // Surface Google's explanation when it has one — e.g. a 403
            // "…API has not been used in project …" is far more actionable
            // than a generic auth failure.
            if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
               !envelope.error.message.isEmpty {
                throw ProviderError.api(message: envelope.error.message, code: envelope.error.status)
            }
            throw ProviderError.unauthorized
        case 429:
            let retryAfter = RetryAfterParser.parse(http.value(forHTTPHeaderField: "retry-after"))
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw ProviderError.network(code: http.statusCode)
        default:
            if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data) {
                // An invalid key is a 400 INVALID_ARGUMENT here, not a 401.
                if envelope.error.message.localizedCaseInsensitiveContains("api key not valid") {
                    throw ProviderError.unauthorized
                }
                throw ProviderError.api(message: envelope.error.message, code: envelope.error.status)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw ProviderError.api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    private static func extractText(_ response: GenerateResponse) throws -> String {
        guard let text = response.candidates?.first?.content.parts.first?.text,
              !text.isEmpty else {
            throw ProviderError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - DTOs

private struct GenerateRequest: Encodable {
    let systemInstruction: Content?
    let contents: [Content]
    let generationConfig: GenerationConfig

    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
    }
}

private struct GenerateResponse: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String?
    }
}

private struct GeminiErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let code: Int
        let message: String
        let status: String?
    }
}

// MARK: - Code Assist DTOs (protocol from the open-source Gemini CLI)

private struct CodeAssistGenerateRequest: Encodable {
    let model: String
    let project: String
    let request: GenerateRequest
}

private struct CodeAssistGenerateResponse: Decodable {
    let response: GenerateResponse?
}

private struct ClientMetadata: Encodable {
    var ideType = "IDE_UNSPECIFIED"
    var platform = "PLATFORM_UNSPECIFIED"
    var pluginType = "GEMINI"
}

private struct LoadCodeAssistRequest: Encodable {
    let metadata: ClientMetadata
}

private struct LoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

private struct OnboardUserRequest: Encodable {
    let tierId: String
    let metadata: ClientMetadata
}

private struct OnboardLRO: Decodable {
    let done: Bool?
    let response: Response?
    struct Response: Decodable {
        let cloudaicompanionProject: Project?
        struct Project: Decodable { let id: String? }
    }
}
