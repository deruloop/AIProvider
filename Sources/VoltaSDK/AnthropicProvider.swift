//
//  AnthropicProvider.swift
//  VoltaSDK
//
//  Developer-key provider for Anthropic's Messages API (Claude).
//  Same shape as OpenAIProvider: typed errors, Codable DTOs, history → the
//  vendor's native message format (D12).
//
//  API notes:
//   - Auth is `x-api-key` (not a Bearer token) + `anthropic-version` header.
//   - `max_tokens` is required by the API.
//   - `temperature` is deliberately NOT sent: recent Claude models
//     (Opus 4.7+) reject sampling parameters with a 400.
//   - The error envelope is {type: "error", error: {type, message}}.
//

import Foundation
import FoundationModels

public struct AnthropicProvider: ModelProvider {

    public let identifier = ProviderIdentifier.anthropic
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let endpoint: URL
    private let urlSession: URLSession
    private let explicitContextSize: Int?

    public init(
        apiKey: String,
        model: String = CloudVendor.anthropic.defaultModel,
        maxTokens: Int = 1000,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        urlSession: URLSession = .shared,
        contextSize: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.explicitContextSize = contextSize
    }

    // MARK: Token awareness (D13) — honest estimates

    /// Known context windows per model family; `nil` for unknown models
    /// (no pre-flight beats a wrong pre-flight). Overridable in the init.
    public var contextSize: Int? {
        if let explicitContextSize { return explicitContextSize }
        return Self.knownContextSize(forModel: model)
    }

    static func knownContextSize(forModel model: String) -> Int? {
        if model.hasPrefix("claude-haiku") { return 200_000 }
        if model.hasPrefix("claude-opus-4-6")
            || model.hasPrefix("claude-opus-4-7")
            || model.hasPrefix("claude-opus-4-8")
            || model.hasPrefix("claude-sonnet-4-6") {
            return 1_000_000
        }
        if model.hasPrefix("claude-") { return 200_000 }
        return nil
    }

    /// ESTIMATE (~4 characters/token): Anthropic has a server-side
    /// count_tokens endpoint, but calling it on every pre-flight would cost
    /// a network round-trip per request — a deliberate trade-off.
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
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
                  !text.isEmpty else {
                throw ProviderError.emptyResponse
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    // MARK: Streaming (D16)

    /// Real token streaming over SSE (`"stream": true`): fragments are the
    /// `content_block_delta` events' `text_delta` payloads; `message_stop`
    /// ends the stream; an `error` event surfaces mid-stream failures.
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
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch {}
            throw Self.mapHTTPFailure(http, data: data)
        }

        var parser = SSEParser()
        do {
            for try await line in bytes.lines {
                guard let event = parser.consume(line) else { continue }
                guard let piece = try? JSONDecoder().decode(
                    StreamEvent.self, from: Data(event.data.utf8)
                ) else { continue }

                switch piece.type {
                case "content_block_delta":
                    if piece.delta?.type == "text_delta",
                       let text = piece.delta?.text,
                       !text.isEmpty {
                        onFragment(text)
                    }
                case "message_stop":
                    return
                case "error":
                    throw Self.mapStreamError(piece.error)
                default:
                    break   // message_start, content_block_start/stop, message_delta, ping
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
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // App-supplied history (D12) → user/assistant turns → current prompt.
        var messages: [MessagesRequest.Message] = []
        for turn in history {
            messages.append(.init(
                role: turn.role == .user ? "user" : "assistant",
                content: turn.text
            ))
        }
        messages.append(.init(role: "user", content: prompt))

        do {
            request.httpBody = try JSONEncoder().encode(
                MessagesRequest(
                    model: model,
                    maxTokens: maxTokens,
                    system: (instructions?.isEmpty == false) ? instructions : nil,
                    messages: messages,
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
            let retryAfter = RetryAfterParser.parse(http.value(forHTTPHeaderField: "retry-after"))
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            // Includes 529 "overloaded" — transient, recoverable by fallback.
            return .network(code: http.statusCode)
        default:
            if let envelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                // Context overflow arrives as a 400 invalid_request_error;
                // single it out because the orchestrator can recover from it.
                if envelope.error.message.localizedCaseInsensitiveContains("prompt is too long") {
                    return .contextWindowExceeded
                }
                return .api(message: envelope.error.message, code: envelope.error.type)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            return .api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }
    }

    /// Mid-stream `error` events, mapped with the same semantics as the
    /// HTTP layer (overloaded → transient network, rate limit → recoverable).
    private static func mapStreamError(_ error: StreamEvent.ErrorPayload?) -> ProviderError {
        guard let error else { return .api(message: "Unknown stream error", code: nil) }
        switch error.type {
        case "overloaded_error":
            return .network(code: 529)
        case "rate_limit_error":
            return .rateLimited(retryAfter: nil)
        default:
            return .api(message: error.message, code: error.type)
        }
    }
}

// MARK: - Dynamic Profiles bridge (D1)

@available(iOS 27.0, macOS 27.0, *)
extension AnthropicProvider: LanguageModelConvertible {
    /// The developer-key provider as a native `LanguageModel` (see the note
    /// on `OpenAIProvider.languageModel`).
    public var languageModel: (any LanguageModel)? {
        CloudAccountLanguageModel(vendor: .anthropic, apiKey: apiKey, model: model)
    }
}

// MARK: - DTOs

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

/// One SSE event of a streamed message. Only the fields the streaming path
/// reads; other event types decode with `nil`s and are skipped.
private struct StreamEvent: Decodable {
    let type: String
    let delta: Delta?
    let error: ErrorPayload?

    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    struct ErrorPayload: Decodable {
        let type: String
        let message: String
    }
}

private struct MessagesResponse: Decodable {
    let content: [Block]
    struct Block: Decodable {
        let type: String
        let text: String?
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let type: String
        let message: String
    }
}
