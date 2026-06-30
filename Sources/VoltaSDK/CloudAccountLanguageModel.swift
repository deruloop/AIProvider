//
//  CloudAccountLanguageModel.swift
//  VoltaSDK
//
//  iOS 27 "front door": exposes a VoltaSDK cloud provider (OpenAI / Claude /
//  Gemini) as a native Foundation Models `LanguageModel`, so the same vendor a
//  user signs into can be handed to a `LanguageModelSession` — and, next, to a
//  Dynamic Profile via the `preferred(_:)` bridge.
//
//  The heavy lifting is reused, not rebuilt: the executor decomposes the
//  framework's `Transcript` into VoltaSDK's (instructions, history, prompt)
//  shape and drives the existing REST `ModelProvider` (the same client the
//  developer-key path uses), then streams the reply into the generation
//  channel. This is the `LanguageModel` + `LanguageModelExecutor` pattern from
//  WWDC 2026 session 339.
//
//  Non-streaming for now — one text fragment — because `ModelProvider.respond`
//  is non-streaming; true token streaming lands when the providers gain it.
//

import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
public struct CloudAccountLanguageModel: LanguageModel {

    public struct Executor: LanguageModelExecutor {
        public typealias Model = CloudAccountLanguageModel

        /// Hashable lookup key — the framework caches one executor per distinct
        /// configuration. The credential lives here for now; a token-provider
        /// indirection (session 339's security guidance) is a later refinement.
        public struct Configuration: Hashable, Sendable {
            public var vendor: CloudVendor
            public var apiKey: String
            public var model: String?

            public init(vendor: CloudVendor, apiKey: String, model: String? = nil) {
                self.vendor = vendor
                self.apiKey = apiKey
                self.model = model
            }
        }

        private let configuration: Configuration

        public init(configuration: Configuration) throws {
            guard !configuration.apiKey.isEmpty else {
                throw ProviderError.unauthorized   // no usable credential
            }
            self.configuration = configuration
        }

        public func prewarm(model: Model, transcript: Transcript) {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: Model,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let parts = FoundationModelsTranscript.decompose(request.transcript)

            // Build the REST client per call so the framework's per-call
            // generation options (session 339) are honoured: temperature and
            // max response tokens map onto the cloud request. The reasoning
            // level from `contextOptions` isn't expressible through these REST
            // clients yet — a known gap.
            var config = AIConfiguration()
            config.developerKey = configuration.apiKey
            config.developerKeyVendor = configuration.vendor
            config.developerKeyModel = configuration.model
            if let temperature = request.generationOptions.temperature {
                config.temperature = temperature
            }
            if let maxTokens = request.generationOptions.maximumResponseTokens {
                config.maxTokens = maxTokens
            }
            guard let provider = AIOrchestrator.buildCloudProvider(from: config) else {
                throw ProviderError.unauthorized
            }

            let text: String
            do {
                text = try await provider.respond(
                    to: parts.prompt,
                    instructions: parts.instructions,
                    history: parts.history
                )
            } catch let error as ProviderError {
                throw Self.mapToFrameworkError(error)
            }
            // One fragment (non-streaming). The rough token estimate keeps the
            // channel's usage reporting populated.
            await channel.send(.response(
                action: .appendText(text, tokenCount: max(1, text.count / 4))
            ))
        }

        /// Maps VoltaSDK's `ProviderError` onto the framework's built-in
        /// `LanguageModelError` where the translation is faithful (session
        /// 339's "prefer the built-in errors"), and rethrows the rest unchanged
        /// — `ProviderError` is a fine *custom* error for the cases the
        /// framework doesn't model (auth, decoding, generic network), which 339
        /// explicitly allows. Only mappings backed by data we actually have are
        /// made; we don't fabricate token counts or language codes to fit a case.
        private static func mapToFrameworkError(_ error: ProviderError) -> any Error {
            switch error {
            case .rateLimited(let retryAfter):
                return LanguageModelError.rateLimited(.init(
                    resetDate: retryAfter.map { Date(timeIntervalSinceNow: $0) },
                    debugDescription: "The upstream provider rate-limited the request."
                ))
            case .guardrailViolation(let message):
                return LanguageModelError.guardrailViolation(.init(debugDescription: message))
            case .cancelled:
                return CancellationError()
            default:
                return error
            }
        }
    }

    private let configuration: Executor.Configuration

    public init(vendor: CloudVendor, apiKey: String, model: String? = nil) {
        self.configuration = Executor.Configuration(
            vendor: vendor, apiKey: apiKey, model: model
        )
    }

    /// Plain text in, plain text out — no vision, tools, or guided generation
    /// claimed (the REST adapter returns unstructured text).
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([])
    }

    public var executorConfiguration: Executor.Configuration {
        configuration
    }
}
