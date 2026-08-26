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
import FoundationModels
import Synchronization

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
        let body = makeBody(prompt: prompt, instructions: instructions, history: history)

        // Credential detection, D15-style: an API key — classic "AIza…"
        // Standard or the new "AQ.…" Auth key (mid-2026 migration) — speaks
        // the Developer API (generativelanguage, x-goog-api-key). Anything
        // else is an OAuth access token (user-account path, "ya29.…") — and
        // OAuth tokens are a DIFFERENT TRANSPORT, not just a different header:
        // generativelanguage rejects them with ACCESS_TOKEN_SCOPE_INSUFFICIENT
        // regardless of granted scopes (observed live). The endpoint that
        // accepts user tokens (cloud-platform scope) is the Code Assist front
        // end, cloudcode-pa.googleapis.com — the same models behind Google's
        // own Gemini CLI sign-in, with its {model, project, request} envelope.
        if isAPIKey {
            do {
                return try await developerAPIRespond(body)
            } catch let error as ProviderError
                where apiKey.hasPrefix("AQ.") && Self.isAuthRejection(error) {
                // Migration fallback (Aug 2026): during Google's move to AQ.
                // Auth keys, some accounts' keys are rejected by the Developer
                // API while being accepted as a Bearer credential on the Code
                // Assist transport (observed live). Try the documented path
                // first, degrade to the one that works.
                return try await codeAssistRespond(body)
            }
        }
        return try await codeAssistRespond(body)
    }

    /// Whether the configured credential is an API key (Developer API
    /// transport) as opposed to an OAuth access token (Code Assist).
    private var isAPIKey: Bool {
        apiKey.hasPrefix("AIza") || apiKey.hasPrefix("AQ.")
    }

    /// Auth-class rejections — the only failures worth retrying on the other
    /// transport during the AQ. key migration.
    private static func isAuthRejection(_ error: ProviderError) -> Bool {
        switch error {
        case .unauthorized:
            return true
        case .api(_, let code):
            return code == "UNAUTHENTICATED" || code == "PERMISSION_DENIED"
        default:
            return false
        }
    }

    /// App-supplied history (D12) → user/model turns → current prompt.
    private func makeBody(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> GenerateRequest {
        var contents: [GenerateRequest.Content] = []
        for turn in history {
            contents.append(.init(
                role: turn.role == .user ? "user" : "model",
                parts: [.init(text: turn.text)]
            ))
        }
        contents.append(.init(role: "user", parts: [.init(text: prompt)]))

        return GenerateRequest(
            systemInstruction: (instructions?.isEmpty == false)
                ? .init(role: nil, parts: [.init(text: instructions!)])
                : nil,
            contents: contents,
            generationConfig: .init(
                temperature: temperature,
                maxOutputTokens: maxTokens + Self.thinkingHeadroom(forModel: model)
            )
        )
    }

    /// Extra output budget requested to cover the model's invisible thinking
    /// pass. Gemini 2.5 and later think by default and those tokens are spent
    /// against `maxOutputTokens` — so a small budget can be consumed entirely
    /// by thinking, returning a candidate with NO text and finishReason
    /// MAX_TOKENS (observed live, August 2026, with the SDK default of 1000).
    /// VoltaSDK's `maxTokens` means "tokens of answer", so the request asks
    /// for answer + headroom. Raising the ceiling costs nothing on its own:
    /// the model thinks (and bills) either way; the cap only decides whether
    /// the answer survives.
    static func thinkingHeadroom(forModel model: String) -> Int {
        // 1.x/2.0 don't think; from 2.5 on it's the default behaviour.
        if model.hasPrefix("gemini-1") || model.hasPrefix("gemini-2.0") { return 0 }
        return 4096
    }

    // MARK: Streaming (D16)

    /// Real token streaming on the Developer API transport
    /// (`streamGenerateContent?alt=sse`): each SSE event is a chunk whose
    /// candidate parts are text deltas. The Code Assist (OAuth) transport has
    /// no SSE equivalent in its envelope, so it stays buffered — the whole
    /// answer as one fragment, like the protocol default. An AQ. key rejected
    /// by the Developer API falls back to buffered Code Assist (the same
    /// migration fallback as `respond`), but only before the first fragment.
    public func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if isAPIKey {
                        let emitted = Mutex(false)
                        do {
                            try await performStream(
                                prompt: prompt, instructions: instructions, history: history
                            ) { fragment in
                                emitted.withLock { $0 = true }
                                continuation.yield(fragment)
                            }
                        } catch let error as ProviderError
                            where apiKey.hasPrefix("AQ.")
                                && !emitted.withLock({ $0 })
                                && Self.isAuthRejection(error) {
                            let text = try await codeAssistRespond(
                                makeBody(prompt: prompt, instructions: instructions, history: history)
                            )
                            continuation.yield(text)
                        }
                    } else {
                        let text = try await respond(
                            to: prompt, instructions: instructions, history: history
                        )
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(
        prompt: String,
        instructions: String?,
        history: [ChatTurn],
        onFragment: @Sendable (String) -> Void
    ) async throws {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("models/\(model):streamGenerateContent"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.encoding("Bad streaming endpoint URL")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else {
            throw ProviderError.encoding("Bad streaming endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            request.httpBody = try JSONEncoder().encode(
                makeBody(prompt: prompt, instructions: instructions, history: history)
            )
        } catch {
            throw ProviderError.encoding("Request encoding failed: \(error.localizedDescription)")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw ProviderError.cancelled }
            throw ProviderError.network(code: urlError.errorCode)
        } catch {
            throw ProviderError.network(code: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(code: -1)
        }
        guard (200...299).contains(http.statusCode) else {
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch {}
            throw Self.mapHTTPFailure(http, data: data)
        }

        var parser = SSEParser()
        var emittedAny = false
        var finishReason: String?
        var blockReason: String?
        var thoughtTokens: Int?
        do {
            for try await line in bytes.lines {
                guard let event = parser.consume(line) else { continue }
                let payload = Data(event.data.utf8)
                // A mid-stream failure arrives as a regular error envelope.
                if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: payload) {
                    throw ProviderError.api(
                        message: envelope.error.message, code: envelope.error.status
                    )
                }
                if let chunk = try? JSONDecoder().decode(GeminiStreamChunk.self, from: payload) {
                    // The last chunks explain how the generation ended — keep
                    // them, so a stream that never produces text can say why.
                    finishReason = chunk.candidates?.first?.finishReason ?? finishReason
                    blockReason = chunk.promptFeedback?.blockReason ?? blockReason
                    thoughtTokens = chunk.usageMetadata?.thoughtsTokenCount ?? thoughtTokens
                    let delta = (chunk.candidates?.first?.content?.parts ?? [])
                        .filter { $0.thought != true }     // thought summaries aren't answer text
                        .compactMap(\.text)
                        .joined()
                    if !delta.isEmpty {
                        emittedAny = true
                        onFragment(delta)
                    }
                }
            }
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw ProviderError.cancelled }
            throw ProviderError.network(code: urlError.errorCode)
        }

        // Same diagnosis as the buffered path: a stream of thought and no
        // answer is a budget (or policy) problem, not a mystery.
        guard emittedAny else {
            throw Self.emptyAnswerError(
                finishReason: finishReason,
                blockReason: blockReason,
                thoughtTokens: thoughtTokens
            )
        }
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
        guard (200...299).contains(http.statusCode) else {
            throw Self.mapHTTPFailure(http, data: data)
        }
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        return data
    }

    /// HTTP errors mapped onto semantic cases (non-2xx only) — identical
    /// semantics for both transports and shared with the streaming path.
    private static func mapHTTPFailure(_ http: HTTPURLResponse, data: Data) -> ProviderError {
        switch http.statusCode {
        case 401, 403:
            // Surface Google's explanation when it has one — e.g. a 403
            // "…API has not been used in project …" is far more actionable
            // than a generic auth failure.
            if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
               !envelope.error.message.isEmpty {
                return .api(message: envelope.error.message, code: envelope.error.status)
            }
            return .unauthorized
        case 429:
            let retryAfter = RetryAfterParser.parse(http.value(forHTTPHeaderField: "retry-after"))
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .network(code: http.statusCode)
        default:
            if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data) {
                // An invalid key is a 400 INVALID_ARGUMENT here, not a 401.
                if envelope.error.message.localizedCaseInsensitiveContains("api key not valid") {
                    return .unauthorized
                }
                return .api(message: envelope.error.message, code: envelope.error.status)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            return .api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    /// Joins every ANSWER part. Two reasons not to read `parts.first`:
    /// long answers arrive split across parts, and thinking models put
    /// thought summaries in the same array, flagged `thought: true`.
    private static func extractText(_ response: GenerateResponse) throws -> String {
        let candidate = response.candidates?.first
        let text = (candidate?.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        throw emptyAnswerError(
            finishReason: candidate?.finishReason,
            blockReason: response.promptFeedback?.blockReason,
            thoughtTokens: response.usageMetadata?.thoughtsTokenCount
        )
    }

    /// Gemini can answer 200 OK with no text for several unrelated reasons;
    /// a bare "empty response" tells the developer nothing about what to
    /// change, so each one gets its own error.
    static func emptyAnswerError(
        finishReason: String?,
        blockReason: String?,
        thoughtTokens: Int?
    ) -> ProviderError {
        if let blockReason {
            return .guardrailViolation("Gemini blocked the prompt (\(blockReason)).")
        }
        switch finishReason {
        case "MAX_TOKENS":
            let spent = thoughtTokens.map { " It spent \($0) tokens thinking first." } ?? ""
            return .api(
                message: "Gemini reached the output-token limit before writing any answer.\(spent) Raise `maxTokens`, or choose a model that thinks less.",
                code: "MAX_TOKENS"
            )
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII":
            return .guardrailViolation("Gemini stopped for policy reasons (\(finishReason ?? "")).")
        case .some(let reason) where reason != "STOP":
            return .api(message: "Gemini returned no text (finishReason: \(reason)).", code: reason)
        default:
            return .emptyResponse
        }
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

/// A tolerant subset of `GenerateContentResponse`: every field is optional
/// because a candidate that produced nothing carries no `content` at all —
/// decoding must survive that and report WHY (`finishReason`) instead of
/// failing.
private struct GenerateResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    let promptFeedback: PromptFeedback?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
        /// `true` marks a thought summary, not answer text.
        let thought: Bool?
    }
    struct UsageMetadata: Decodable {
        let thoughtsTokenCount: Int?
        let candidatesTokenCount: Int?
    }
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }
}

/// One SSE chunk of a streamed generation — the same shape; final chunks
/// carry the finish reason and usage with no content.
private typealias GeminiStreamChunk = GenerateResponse

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

// MARK: - Dynamic Profiles bridge (D1)

@available(iOS 27.0, macOS 27.0, *)
extension GeminiProvider: LanguageModelConvertible {
    /// The developer-key provider as a native `LanguageModel` (see the note
    /// on `OpenAIProvider.languageModel`).
    public var languageModel: (any LanguageModel)? {
        CloudAccountLanguageModel(vendor: .gemini, apiKey: apiKey, model: model)
    }
}
