//
//  ModelProvider.swift
//  VoltaSDK
//
//  The protocol shared by all model providers.
//  Evolution of the original `ChatGptRepository`: same idea (interface +
//  mock), but provider-agnostic so it can host on-device, developer key,
//  and in the future (iOS 27) PCC, Gemini, Claude.
//

import Foundation

// MARK: - Provider identity

/// Extensible provider identifier.
/// Deliberately not a closed enum: new providers (pcc, gemini, claude)
/// can be added without breaking existing code.
public struct ProviderIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let onDevice  = ProviderIdentifier("on-device")
    public static let openAI    = ProviderIdentifier("openai")
    public static let anthropic = ProviderIdentifier("anthropic")
    public static let gemini    = ProviderIdentifier("gemini")
    /// Private Cloud Compute (iOS 27): Apple-hosted, free with a per-user
    /// daily quota, no key. Sits between on-device and the developer key.
    public static let privateCloudCompute = ProviderIdentifier("private-cloud-compute")

    /// A user-account provider (iOS 27): the user's *own* OpenAI / Claude /
    /// Gemini account, billed to them, reached through the public
    /// `LanguageModel` protocol. Distinct from the developer-key providers
    /// above so the chain and pickers can tell them apart.
    public static func userAccount(_ vendor: CloudVendor) -> ProviderIdentifier {
        ProviderIdentifier("user-\(vendor.rawValue)")
    }
}

// MARK: - Privacy level

/// How "far" from the user's data a provider operates.
/// Comparable because the orchestrator already uses it on iOS 26 to detect
/// privacy downgrades during fallback (see `PrivacyDisclosure`).
public enum PrivacyLevel: Int, Sendable, Comparable {
    case external   = 0   // data leaves for a third-party provider (e.g. OpenAI dev key)
    case appleCloud = 1   // Private Cloud Compute (iOS 27)
    case onDevice   = 2   // never leaves the device

    public static func < (lhs: PrivacyLevel, rhs: PrivacyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Availability

public enum ProviderAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Snapshot of a provider's state, in preference order.
/// Designed for UI (pickers, diagnostics) but independent of SwiftUI.
public struct ProviderStatus: Sendable, Identifiable {
    public let identifier: ProviderIdentifier
    public let privacyLevel: PrivacyLevel
    public let availability: ProviderAvailability
    /// Context window in tokens, if the provider knows it (D13).
    public let contextSize: Int?

    public var id: ProviderIdentifier { identifier }

    public init(
        identifier: ProviderIdentifier,
        privacyLevel: PrivacyLevel,
        availability: ProviderAvailability,
        contextSize: Int? = nil
    ) {
        self.identifier = identifier
        self.privacyLevel = privacyLevel
        self.availability = availability
        self.contextSize = contextSize
    }
}

// MARK: - Typed errors

/// Replaces the original manager's `return nil`: every failure carries its
/// cause, so the orchestrator can decide whether to fall back or stop.
public enum ProviderError: Error, Sendable, Equatable {
    /// Quota/limit reached (HTTP 429, or on-device rate limit in background).
    /// The main reason to fall back to the next provider.
    case rateLimited(retryAfter: TimeInterval?)
    /// Wrong or missing key (HTTP 401/403). Terminal: retrying is pointless.
    case unauthorized
    /// Network problem. Candidate for retry or fallback.
    case network(code: Int)
    /// Empty response from the server.
    case emptyResponse
    /// Request-encoding error (client side, before the network).
    case encoding(String)
    /// Response-decoding error.
    case decoding(String)
    /// Application error returned by the provider's API.
    case api(message: String, code: String?)
    /// The prompt exceeds the model's context window.
    /// Recoverable: a later provider may have a larger window.
    case contextWindowExceeded
    /// Safety guardrail triggered (on-device). Terminal by choice:
    /// auto-forwarding content Apple deemed unsafe to an external provider
    /// would be an unrequested privacy downgrade.
    case guardrailViolation(String)
    /// Language/locale not supported by the model. Recoverable: cloud
    /// models cover more languages than the on-device model.
    case unsupportedLanguage
    /// Other unmapped on-device generation error.
    case generation(String)
    /// No usable provider at the moment.
    case noProviderAvailable
    /// All remaining providers were excluded by the privacy policy
    /// (`.denyDowngrade` or a declined `.askOnPrivacyChange`).
    case privacyRestricted
    /// Operation cancelled.
    case cancelled

    /// Whether this error allows trying the next provider in the chain.
    /// (On iOS 27 this same property will drive the quota-aware fallback.)
    public var isRecoverableByFallback: Bool {
        switch self {
        case .rateLimited, .network, .contextWindowExceeded,
             .unsupportedLanguage, .noProviderAvailable:
            return true
        case .unauthorized, .emptyResponse, .encoding, .decoding, .api,
             .guardrailViolation, .generation, .privacyRestricted, .cancelled:
            return false
        }
    }
}

// MARK: - Provider protocol

public protocol ModelProvider: Sendable {
    var identifier: ProviderIdentifier { get }
    var privacyLevel: PrivacyLevel { get }

    /// Runtime check: is the provider usable right now?
    /// (On-device → Apple Intelligence present/enabled/ready.
    ///  Developer key → key configured. iOS 27 → remaining quota too.)
    func availability() async -> ProviderAvailability

    /// Non-streaming response. Stable signature: unchanged on iOS 27.
    ///
    /// `history` carries the previous conversation turns, supplied by the
    /// app (D12): the provider remembers nothing between calls, but every
    /// call is self-contained and can therefore be served by any provider
    /// in the fallback chain.
    func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String

    // MARK: Optional capability: token awareness (D13)

    /// Context window size in tokens, if known.
    /// `nil` = unknown: the orchestrator will skip pre-flight.
    var contextSize: Int? { get }

    /// Number of tokens the call would occupy (prompt + instructions +
    /// history), if the provider can count or estimate them. `nil` = can't.
    /// On-device: exact count from iOS 26.4, `nil` before.
    /// Cloud: honest estimate (no official client-side tokenizer).
    func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int?
}

public extension ModelProvider {
    /// Convenience for one-shot calls (no conversation).
    func respond(to prompt: String, instructions: String?) async throws -> String {
        try await respond(to: prompt, instructions: instructions, history: [])
    }

    /// Default: capability unsupported. Existing custom providers keep
    /// compiling and simply don't participate in pre-flight.
    var contextSize: Int? { nil }

    func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? { nil }
}
