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
//  AUTH (session 339): the credential is NOT a raw string baked into the
//  executor's hashable `Configuration`. It's a **token provider** on the model
//  — `() async throws -> String` — resolved *per call*. The executor reaches it
//  through the `model` it's handed on each `respond`, so the `Configuration`
//  stays a pure cache key and OAuth-refreshed tokens or Keychain reads work
//  without a global registry. A static-key convenience initializer covers the
//  simple case.
//
//  Non-streaming for now — one text fragment — because `ModelProvider.respond`
//  is non-streaming; true token streaming lands when the providers gain it.
//

import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
public struct CloudAccountLanguageModel: LanguageModel {

    /// Resolves the current credential when a call is made — a static key, a
    /// value read from the Keychain, or a freshly refreshed OAuth token.
    public typealias TokenProvider = @Sendable () async throws -> String

    let vendor: CloudVendor
    let modelName: String?
    let token: TokenProvider

    /// Token-provider initializer (OAuth / Keychain / anything async).
    public init(
        vendor: CloudVendor,
        model: String? = nil,
        token: @escaping TokenProvider
    ) {
        self.vendor = vendor
        self.modelName = model
        self.token = token
    }

    /// Static-key convenience — wraps the key in a token provider.
    public init(vendor: CloudVendor, apiKey: String, model: String? = nil) {
        self.init(vendor: vendor, model: model, token: { apiKey })
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = CloudAccountLanguageModel

        /// Pure cache key — the framework shares one executor per distinct
        /// configuration. Deliberately holds NO credential (session 339).
        public struct Configuration: Hashable, Sendable {
            public var vendor: CloudVendor
            public var model: String?
        }

        public init(configuration: Configuration) throws {}

        public func prewarm(model: Model, transcript: Transcript) {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: Model,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            // Resolve the credential for this call from the model's token
            // provider (may hit the Keychain or refresh an OAuth token).
            let apiKey = try await model.token()
            guard !apiKey.isEmpty else { throw ProviderError.unauthorized }

            let parts = FoundationModelsTranscript.decompose(request.transcript)

            // Build the REST client per call so the framework's per-call
            // generation options (session 339) are honoured: temperature and
            // max response tokens map onto the cloud request. The reasoning
            // level from `contextOptions` isn't expressible through these REST
            // clients yet — a known gap.
            var config = AIConfiguration()
            config.developerKey = apiKey
            config.developerKeyVendor = model.vendor
            config.developerKeyModel = model.modelName
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

    /// Plain text in, plain text out — no vision, tools, or guided generation
    /// claimed (the REST adapter returns unstructured text).
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([])
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(vendor: vendor, model: modelName)
    }
}
