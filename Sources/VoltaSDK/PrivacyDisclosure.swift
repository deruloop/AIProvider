//
//  PrivacyDisclosure.swift
//  VoltaSDK
//
//  Disclosure of privacy downgrades during fallback.
//
//  Why this exists already on iOS 26: with `.preferOnDevice`, a transient
//  failure of the on-device model silently re-sends the user's prompt to an
//  external provider (OpenAI). That privacy downgrade happens TODAY, not
//  only on iOS 27. The mechanism deliberately matches the iOS 27 design
//  (.silent / .notify / .askOnPrivacyChange), so the extension won't
//  change the API.
//
//  Only the developer knows their app's sensitivity: that's why the policy
//  is a configuration choice, not a hardcoded default.
//

import Foundation

/// Describes a privacy-threshold crossing: the provider about to answer
/// operates at a lower level than the first provider in the chain.
public struct PrivacyDowngrade: Sendable, Equatable {
    /// The preferred provider's level (the chain's implicit "promise").
    public let from: PrivacyLevel
    /// The level of the provider about to be used.
    public let to: PrivacyLevel
    /// Who is about to receive the prompt.
    public let provider: ProviderIdentifier

    public init(from: PrivacyLevel, to: PrivacyLevel, provider: ProviderIdentifier) {
        self.from = from
        self.to = to
        self.provider = provider
    }
}

/// Policy the orchestrator applies when fallback crosses a privacy
/// threshold downwards.
public enum PrivacyDisclosure: Sendable {
    /// No signal: the fallback is transparent.
    case silent
    /// The fallback proceeds; the downgrade is recorded to the unified log
    /// (subsystem "VoltaSDK", category "privacy"). The DEFAULT since D18:
    /// a fully silent default was too quiet for a privacy-first SDK — an
    /// adopter could ship cloud fallbacks without ever noticing them —
    /// while a log line costs nothing, reaches no end user, and surfaces
    /// in Console/Instruments during development.
    case log
    /// The fallback proceeds, but the handler is notified (e.g. to show a
    /// "response generated in the cloud" banner). The handler is synchronous
    /// and cannot block the fallback.
    case notify(@Sendable (PrivacyDowngrade) -> Void)
    /// The fallback pauses and asks: `true` to proceed, `false` to skip the
    /// provider. Typically wired to an alert in the UI.
    case askOnPrivacyChange(@Sendable (PrivacyDowngrade) async -> Bool)
    /// Providers below the first provider's level are never used. If only
    /// they remain, `respond` throws `.privacyRestricted`.
    case denyDowngrade
}
