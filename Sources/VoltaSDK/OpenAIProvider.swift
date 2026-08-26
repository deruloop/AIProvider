//
//  OpenAIProvider.swift
//  VoltaSDK
//
//  Evolution of the original ChatGptManager.
//  Key differences from the primitive version:
//   - `throws -> String` signature instead of `-> String?` (errors aren't lost)
//   - errors mapped onto ProviderError (429 → .rateLimited, 401 → .unauthorized, ...)
//   - model and parameters configurable instead of hardcoded
//   - request/response via Codable instead of JSONSerialization
//
//  SECURITY NOTE (iOS 26): here the developer key travels in a direct call
//  from the device to the OpenAI endpoint. The key belongs to the developer
//  (not the user), but it is present in device traffic. For high-volume
//  production consider a server-side proxy. On iOS 27 this provider becomes
//  replaceable by the native integration conforming to the `LanguageModel`
//  protocol.
//

import Foundation
import FoundationModels

public struct OpenAIProvider: ModelProvider {

    public let identifier = ProviderIdentifier.openAI
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let temperature: Double
    private let endpoint: URL
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        maxTokens: Int = 1000,
        temperature: Double = 0.3,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        urlSession: URLSession = .shared,
        contextSize: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.explicitContextSize = contextSize
    }

    // MARK: Token awareness (D13) — honest estimates

    /// Context window: the one passed to the initializer if present,
    /// otherwise best-effort from known models. `nil` for unknown models:
    /// no pre-flight beats a wrong pre-flight.
    private let explicitContextSize: Int?

    public var contextSize: Int? {
        if let explicitContextSize { return explicitContextSize }
        return Self.knownContextSize(forModel: model)
    }

    /// ESTIMATE (~4 characters/token): OpenAI offers no official client-side
    /// tokenizer. Slightly undercounting is intentional: pre-flight must
    /// never discard a usable provider; true overflow is still covered by
    /// the reactive path (.contextWindowExceeded).
    public func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? {
        var characters = prompt.count + (instructions?.count ?? 0)
        for turn in history { characters += turn.text.count }
        return (characters + 3) / 4
    }

    static func knownContextSize(forModel model: String) -> Int? {
        if model.hasPrefix("gpt-4.1") { return 1_047_576 }
        if model.hasPrefix("gpt-4o") { return 128_000 }
        if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            return 200_000
        }
        return nil
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
        let request = try makeRequest(
            prompt: prompt, instructions: instructions, history: history, stream: false
        )

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

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw ProviderError.emptyResponse
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    // MARK: Streaming (D16)

    /// Real token streaming over SSE (`"stream": true`): fragments are the
    /// chunks' `delta.content`; `data: [DONE]` ends the stream.
    public func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(
                        prompt: prompt, instructions: instructions, history: history
                    ) { continuation.yield($0) }
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
        let request = try makeRequest(
            prompt: prompt, instructions: instructions, history: history, stream: true
        )

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
            // Non-2xx: the body is a regular JSON error — collect it
            // (best-effort) and map it exactly like the buffered path.
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch {}
            throw Self.mapHTTPFailure(http, data: data)
        }

        var parser = SSEParser()
        do {
            for try await line in bytes.lines {
                guard let event = parser.consume(line) else { continue }
                if event.data == "[DONE]" { return }
                let payload = Data(event.data.utf8)
                // A mid-stream failure arrives as a regular error envelope.
                if let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: payload) {
                    throw ProviderError.api(
                        message: envelope.error.message, code: envelope.error.code
                    )
                }
                if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: payload),
                   let delta = chunk.choices.first?.delta.content,
                   !delta.isEmpty {
                    onFragment(delta)
                }
            }
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw ProviderError.cancelled }
            throw ProviderError.network(code: urlError.errorCode)
        }
    }

    // MARK: Request building and error mapping (shared by both paths)

    private func makeRequest(
        prompt: String,
        instructions: String?,
        history: [ChatTurn],
        stream: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // system → app-supplied history (D12) → current prompt.
        var messages: [ChatRequest.Message] = []
        if let instructions, !instructions.isEmpty {
            messages.append(.init(role: "system", content: instructions))
        }
        for turn in history {
            messages.append(.init(
                role: turn.role == .user ? "user" : "assistant",
                content: turn.text
            ))
        }
        messages.append(.init(role: "user", content: prompt))

        do {
            request.httpBody = try JSONEncoder().encode(
                ChatRequest(
                    model: model,
                    messages: messages,
                    maxCompletionTokens: maxTokens,
                    temperature: temperature,
                    stream: stream
                )
            )
        } catch {
            throw ProviderError.encoding("Request encoding failed: \(error.localizedDescription)")
        }
        return request
    }

    /// HTTP errors mapped onto semantic cases (non-2xx only).
    private static func mapHTTPFailure(_ http: HTTPURLResponse, data: Data) -> ProviderError {
        switch http.statusCode {
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            return .rateLimited(retryAfter: retryAfter)
        default:
            if let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                // Context-window overflow arrives as an application error:
                // we single it out because the orchestrator can recover from it.
                if envelope.error.code == "context_length_exceeded" {
                    return .contextWindowExceeded
                }
                return .api(message: envelope.error.message, code: envelope.error.code)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            return .api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }
    }

    /// `Retry-After` parsing, shared with the other cloud providers.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        RetryAfterParser.parse(value)
    }
}

// MARK: - Dynamic Profiles bridge (D1)

@available(iOS 27.0, macOS 27.0, *)
extension OpenAIProvider: LanguageModelConvertible {
    /// The developer-key provider as a native `LanguageModel`: the same REST
    /// client, wrapped in `CloudAccountLanguageModel` keyed by vendor + key.
    /// Generation options (temperature, max tokens) then come from the
    /// consuming session/profile per call — the profile owns them.
    public var languageModel: (any LanguageModel)? {
        CloudAccountLanguageModel(vendor: .openAI, apiKey: apiKey, model: model)
    }
}

// MARK: - DTOs

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let maxCompletionTokens: Int
    let temperature: Double
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        // `max_tokens` is deprecated: newer models only accept this one.
        case maxCompletionTokens = "max_completion_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

/// One SSE chunk of a streamed completion.
private struct StreamChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let delta: Delta
        struct Delta: Decodable { let content: String? }
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}
