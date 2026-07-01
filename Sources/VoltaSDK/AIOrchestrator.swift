//
//  AIOrchestrator.swift
//  VoltaSDK
//
//  The orchestrator and the stable public API.
//  On iOS 26 it resolves between two providers (on-device + developer key)
//  with automatic fallback and privacy disclosure. The same public surface
//  will carry iOS 27, which adds PCC, user-account providers, and the
//  per-need chain (.lightweight / .reasoning / .largeContext).
//
//  Naming note: the type is NOT named after the module (VoltaSDK)
//  because in Swift a type that shadows its own module makes it impossible
//  to qualify other symbols (`VoltaSDK.Xyz` would always resolve the
//  type, never the module). "Orchestrator" also reflects the framework's
//  real value: model resolution, not agent execution.
//

import Foundation
import Synchronization

// MARK: - Selection preference

/// Embryonic form of the fallback. On iOS 27 it becomes a richer chain
/// (per-need: .lightweight / .reasoning / .largeContext, with PCC quotas).
public enum ModelPreference: Sendable, CaseIterable {
    /// On-device if available, otherwise developer key. Sensible default.
    case preferOnDevice
    /// Developer key first, on-device as the safety net.
    case preferDeveloperKey
    /// On-device only. Errors if unavailable.
    case onDeviceOnly
    /// Developer key only.
    case developerKeyOnly
}

// MARK: - Configuration

/// A user's own cloud account (iOS 27): the user supplies the credential and
/// is billed, as opposed to the developer key (`developerKey`) the app pays
/// for. Reached through the public `LanguageModel` protocol.
///
/// The credential is a **token provider**, resolved when a call is made
/// (session 339): a static key, a Keychain read, or a refreshed OAuth token
/// all fit. A static-key convenience initializer covers the simple case.
public struct UserAccount: Sendable {
    public var vendor: CloudVendor
    /// Model name within the vendor; `nil` = the vendor's default.
    public var model: String?
    /// Resolves the current credential at call time.
    public var token: @Sendable () async throws -> String
    /// Whether the account is connected — drives availability without a
    /// network call. `true` by default for token providers; the key
    /// convenience derives it from the key being non-empty.
    public var isConnected: Bool

    /// Token-provider initializer (OAuth / Keychain / any async source).
    public init(
        vendor: CloudVendor,
        model: String? = nil,
        isConnected: Bool = true,
        token: @escaping @Sendable () async throws -> String
    ) {
        self.vendor = vendor
        self.model = model
        self.isConnected = isConnected
        self.token = token
    }

    /// Static-key convenience. An empty key means "not connected".
    public init(vendor: CloudVendor, apiKey: String, model: String? = nil) {
        self.init(
            vendor: vendor,
            model: model,
            isConnected: !apiKey.isEmpty,
            token: { apiKey }
        )
    }
}

public struct AIConfiguration: Sendable {
    /// Enables the on-device model (requires Apple Intelligence on the device).
    public var enableOnDevice: Bool = true

    /// Enables Private Cloud Compute (iOS 27+): Apple's free "powered" tier —
    /// no key, no account, a per-user daily quota (D6). Defaults on: it
    /// degrades gracefully (skipped where the device/entitlement/quota make it
    /// unavailable) and ignored entirely on iOS 26. Participates only in the
    /// `.preferOnDevice` / `.preferDeveloperKey` chains, never in the strict
    /// `.onDeviceOnly` / `.developerKeyOnly` modes.
    public var enablePrivateCloudCompute: Bool = true

    /// The user's own cloud accounts (iOS 27+). Each becomes a provider in the
    /// fallback chain, reached through the public `LanguageModel` protocol.
    /// Empty by default; ignored entirely on iOS 26. Like the developer key,
    /// these are external-privacy providers and never auto-selected by the
    /// `ModelSelector` (the user must connect the account first).
    public var userAccounts: [UserAccount] = []

    /// Cloud provider developer key. Accepts OpenAI, Anthropic (Claude),
    /// or Google (Gemini) keys — the vendor is auto-detected from the key
    /// format (D15). Injected by the app, typically from an Xcode secret.
    /// If nil, no cloud provider is created.
    public var developerKey: String? = nil

    /// Vendor the key belongs to. `nil` = auto-detect from the key format
    /// (`sk-ant-…` → Anthropic, `AIza…` → Gemini, `sk-…` → OpenAI);
    /// set explicitly when detection isn't possible.
    public var developerKeyVendor: CloudVendor? = nil

    /// Model to use with the developer key. The model name belongs to the
    /// key's vendor (e.g. "gpt-4o-mini" for OpenAI, "claude-opus-4-8" for
    /// Anthropic, "gemini-2.5-flash" for Gemini — find the current names at
    /// each vendor's `CloudVendor.modelDocumentationURL`). `nil` = the
    /// vendor's default model.
    public var developerKeyModel: String? = nil

    public var maxTokens: Int = 1000
    public var temperature: Double = 0.3

    /// Preference order between on-device and developer key.
    public var preference: ModelPreference = .preferOnDevice

    /// What to do when fallback crosses a privacy threshold downwards
    /// (e.g. on-device → OpenAI). See `PrivacyDisclosure`.
    public var privacyDisclosure: PrivacyDisclosure = .silent

    public init() {}
}

// MARK: - Context pressure (D13)

/// How much of the resolved provider's context window the current
/// conversation would occupy. This is the information the app needs to
/// decide WHEN to trim or summarize the history (the policy stays with
/// the app, D12).
public struct ContextUsage: Sendable, Equatable {
    public let tokens: Int
    public let contextSize: Int
    public let provider: ProviderIdentifier

    /// Occupied fraction, 0...1+ (can exceed 1 if already past the window).
    public var fraction: Double {
        contextSize > 0 ? Double(tokens) / Double(contextSize) : 0
    }
}

// MARK: - Detailed response

/// Response enriched with provenance: essential for UIs that want to show
/// which model answered and at which privacy level.
public struct AIResponse: Sendable {
    public let text: String
    public let provider: ProviderIdentifier
    public let privacyLevel: PrivacyLevel
}

// MARK: - Orchestrator

/// An actor even though its state is immutable today: the planned
/// extensions (PCC quota tracking, multi-turn session caches) will need
/// protected mutable state.
public actor AIOrchestrator {

    private let orderedProviders: [any ModelProvider]
    private let privacyDisclosure: PrivacyDisclosure
    /// Tokens reserved for the response during pre-flight (D13): a call that
    /// exactly fills the window would fail at generation anyway.
    private let responseTokenReserve: Int

    // MARK: Explicit init (recommended: no global state)

    public init(configuration: AIConfiguration) {
        self.orderedProviders = Self.buildProviders(from: configuration)
        self.privacyDisclosure = configuration.privacyDisclosure
        self.responseTokenReserve = configuration.maxTokens
    }

    /// Direct init with pre-built providers — useful for tests or for
    /// plugging in custom providers.
    public init(
        providers: [any ModelProvider],
        privacyDisclosure: PrivacyDisclosure = .silent,
        responseTokenReserve: Int = 0
    ) {
        self.orderedProviders = providers
        self.privacyDisclosure = privacyDisclosure
        self.responseTokenReserve = responseTokenReserve
    }

    // MARK: Optional singleton for convenience

    public static let shared = AIOrchestrator(configuration: AIConfiguration())

    /// App-configured override. A Mutex because in Swift 6 a non-isolated
    /// `static var` is not concurrency-safe.
    private static let _sharedOverride = Mutex<AIOrchestrator?>(nil)

    /// Configures the shared instance. Call once at app launch.
    /// Example:
    /// ```
    /// AIOrchestrator.configure {
    ///     $0.enableOnDevice = true
    ///     $0.developerKey = Secrets.openAIKey
    ///     $0.developerKeyModel = "gpt-4o-mini"
    ///     $0.preference = .preferOnDevice
    /// }
    /// ```
    public static func configure(_ build: (inout AIConfiguration) -> Void) {
        var config = AIConfiguration()
        build(&config)
        let orchestrator = AIOrchestrator(configuration: config)
        _sharedOverride.withLock { $0 = orchestrator }
    }

    /// The active instance (configured override, otherwise the default).
    public static var active: AIOrchestrator {
        _sharedOverride.withLock { $0 } ?? shared
    }

    // MARK: Main API

    /// Generates a response using the best available provider according to
    /// the preference, falling back automatically to later providers when
    /// one is unavailable or fails recoverably (429, network, context
    /// window, language). Stable signature: unchanged on iOS 27.
    ///
    /// `history` (D12): the previous conversation turns, owned and supplied
    /// by the app. The framework never stores them; it forwards them to the
    /// chosen provider. Every call is self-contained, so fallback works
    /// mid-conversation too.
    public func respond(
        to prompt: String,
        instructions: String? = nil,
        history: [ChatTurn] = []
    ) async throws -> String {
        try await respondDetailed(to: prompt, instructions: instructions, history: history).text
    }

    /// Like `respond`, but also returns which provider answered and its
    /// privacy level (for banners/badges in UI).
    public func respondDetailed(
        to prompt: String,
        instructions: String? = nil,
        history: [ChatTurn] = []
    ) async throws -> AIResponse {
        guard let first = orderedProviders.first else {
            throw ProviderError.noProviderAvailable
        }

        // The chain's privacy "promise" is the preferred provider's level:
        // going below it is a downgrade.
        let baseline = first.privacyLevel
        var lastError: ProviderError = .noProviderAvailable

        for provider in orderedProviders {
            // Skip unavailable providers without even trying.
            if case .unavailable = await provider.availability() {
                continue
            }

            // Context pre-flight (D13): if the provider can count and the
            // call cannot fit its window, skip it as if it had already
            // thrown .contextWindowExceeded — without paying for a doomed
            // generation. Runs BEFORE the privacy gate: never ask the user
            // about a provider that can't serve the call.
            if let window = provider.contextSize,
               let needed = await provider.tokenCount(
                   prompt: prompt, instructions: instructions, history: history
               ),
               needed + responseTokenReserve >= window {
                lastError = .contextWindowExceeded
                continue
            }

            // Privacy gate: applied before sending any data.
            if provider.privacyLevel < baseline {
                let downgrade = PrivacyDowngrade(
                    from: baseline,
                    to: provider.privacyLevel,
                    provider: provider.identifier
                )
                switch privacyDisclosure {
                case .silent:
                    break
                case .notify(let handler):
                    handler(downgrade)
                case .askOnPrivacyChange(let handler):
                    guard await handler(downgrade) else {
                        lastError = .privacyRestricted
                        continue
                    }
                case .denyDowngrade:
                    lastError = .privacyRestricted
                    continue
                }
            }

            do {
                let text = try await provider.respond(
                    to: prompt,
                    instructions: instructions,
                    history: history
                )
                return AIResponse(
                    text: text,
                    provider: provider.identifier,
                    privacyLevel: provider.privacyLevel
                )
            } catch let error as ProviderError {
                lastError = error
                if error.isRecoverableByFallback {
                    continue        // try the next provider
                }
                throw error         // terminal error (auth, guardrail, decoding, ...)
            }
        }

        throw lastError
    }

    // MARK: Resolution (the primitive, not the convenience)

    /// Returns the first available provider in the chain WITHOUT executing
    /// anything. This is the "model resolution" primitive — the framework's
    /// core value. On iOS 27 it evolves into `preferred(_ need:)`, returning
    /// a `LanguageModel` to pass into a native Dynamic Profile.
    ///
    /// Note: it applies availability only, not the interactive disclosure
    /// (.askOnPrivacyChange only makes sense inside the `respond` loop).
    /// With `.denyDowngrade`, providers below the threshold are excluded.
    public func resolveProvider() async throws -> any ModelProvider {
        guard let first = orderedProviders.first else {
            throw ProviderError.noProviderAvailable
        }
        let baseline = first.privacyLevel

        for provider in orderedProviders {
            if case .unavailable = await provider.availability() {
                continue
            }
            if case .denyDowngrade = privacyDisclosure,
               provider.privacyLevel < baseline {
                continue
            }
            return provider
        }
        throw ProviderError.noProviderAvailable
    }

    /// Pressure of the current conversation on the window of the provider
    /// that would answer now (D13). `nil` if no provider is available or
    /// the resolved one can't count (e.g. on-device before 26.4).
    /// The app uses it to decide when to trim/summarize the history (D12).
    public func contextUsage(
        instructions: String? = nil,
        history: [ChatTurn]
    ) async -> ContextUsage? {
        guard let provider = try? await resolveProvider(),
              let window = provider.contextSize,
              let tokens = await provider.tokenCount(
                  prompt: "", instructions: instructions, history: history
              )
        else { return nil }
        return ContextUsage(
            tokens: tokens,
            contextSize: window,
            provider: provider.identifier
        )
    }

    // MARK: Introspection (for UI and diagnostics)

    /// The currently usable providers, in preference order.
    public func availableProviders() async -> [ProviderIdentifier] {
        var result: [ProviderIdentifier] = []
        for provider in orderedProviders {
            if case .available = await provider.availability() {
                result.append(provider.identifier)
            }
        }
        return result
    }

    /// Full status of every provider in the chain (including unavailable
    /// ones, with the reason). Designed for picker/diagnostic UIs.
    public func providerStatuses() async -> [ProviderStatus] {
        var result: [ProviderStatus] = []
        for provider in orderedProviders {
            result.append(ProviderStatus(
                identifier: provider.identifier,
                privacyLevel: provider.privacyLevel,
                availability: await provider.availability(),
                contextSize: provider.contextSize
            ))
        }
        return result
    }

    // MARK: Provider construction

    private static func buildProviders(from config: AIConfiguration) -> [any ModelProvider] {
        let onDevice: (any ModelProvider)? = config.enableOnDevice ? OnDeviceProvider() : nil
        let pcc = buildPrivateCloudComputeProvider(from: config)
        let cloud = buildCloudProvider(from: config)
        // User-account providers (iOS 27) are additional external options the
        // user connects; they trail the app's own providers in the default
        // order, and the user can re-lead the chain via the picker.
        let userAccounts = buildUserAccountProviders(from: config)

        // Ordered by privacy: on-device (max) → PCC (.appleCloud) → developer
        // key (external) → user accounts (external). PCC is a fallback tier, not
        // a destination of its own, so it (and user accounts) join the two
        // "prefer" chains but not the strict "only" modes.
        switch config.preference {
        case .preferOnDevice:
            return [onDevice, pcc, cloud].compactMap { $0 } + userAccounts
        case .preferDeveloperKey:
            return [cloud, pcc, onDevice].compactMap { $0 } + userAccounts
        case .onDeviceOnly:
            return [onDevice].compactMap { $0 }
        case .developerKeyOnly:
            return [cloud].compactMap { $0 }
        }
    }

    /// Builds a chain provider for each configured user account (iOS 27+),
    /// reached through the public `LanguageModel` protocol via
    /// `CloudAccountLanguageModel`. Empty on iOS 26 or when none are configured
    /// — the single `@available` gate for this tier (D14).
    static func buildUserAccountProviders(from config: AIConfiguration) -> [any ModelProvider] {
        guard !config.userAccounts.isEmpty else { return [] }
        if #available(iOS 27.0, macOS 27.0, *) {
            return config.userAccounts.map { account in
                LanguageModelProvider(
                    identifier: .userAccount(account.vendor),
                    privacyLevel: .external,
                    model: CloudAccountLanguageModel(
                        vendor: account.vendor,
                        model: account.model,
                        token: account.token
                    ),
                    connected: account.isConnected
                )
            }
        }
        return []
    }

    /// Private Cloud Compute is the single iOS 27 wire-in point (D14): a
    /// type-level `@available` gate here, nothing scattered through the
    /// orchestration logic — the chain just gets one provider longer on iOS 27.
    static func buildPrivateCloudComputeProvider(
        from config: AIConfiguration
    ) -> (any ModelProvider)? {
        guard config.enablePrivateCloudCompute else { return nil }
        if #available(iOS 27.0, macOS 27.0, *) {
            return PrivateCloudComputeProvider()
        }
        return nil
    }

    /// The developer key is vendor-agnostic (D15): explicit vendor wins,
    /// otherwise it's detected from the key format, with OpenAI as the
    /// documented fallback for unrecognized formats.
    static func buildCloudProvider(from config: AIConfiguration) -> (any ModelProvider)? {
        guard let key = config.developerKey, !key.isEmpty else { return nil }
        let vendor = config.developerKeyVendor ?? CloudVendor.detect(fromKey: key) ?? .openAI
        let model = config.developerKeyModel ?? vendor.defaultModel

        switch vendor {
        case .openAI:
            return OpenAIProvider(
                apiKey: key,
                model: model,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )
        case .anthropic:
            // No temperature: recent Claude models reject sampling params.
            return AnthropicProvider(
                apiKey: key,
                model: model,
                maxTokens: config.maxTokens
            )
        case .gemini:
            return GeminiProvider(
                apiKey: key,
                model: model,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )
        }
    }
}
