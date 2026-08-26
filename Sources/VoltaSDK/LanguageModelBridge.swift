//
//  LanguageModelBridge.swift
//  VoltaSDK
//
//  The Dynamic Profiles bridge (D1): providers that can hand back the native
//  Apple `LanguageModel` they represent. `AIOrchestrator.preferred()` walks
//  the chain with the same rules as `resolveProvider()` and returns the
//  winning provider's model — ready to drop into a native Dynamic Profile
//  (`.model(orchestrator.preferred())`) or a `LanguageModelSession(model:)`.
//
//  This is the D1 thesis made concrete: VoltaSDK never owns an "agent"
//  abstraction — the developer writes their profile entirely in Apple's
//  language, and VoltaSDK contributes exactly one expression: which model.
//
//  Conformances live next to each provider (they need the provider's private
//  state): on-device → `SystemLanguageModel` (here), PCC → its entitled model
//  instance, wrapped models → the model itself, and the developer-key REST
//  providers → a `CloudAccountLanguageModel` over the same client.
//

import Foundation
import FoundationModels

/// A provider that can expose itself as a native Apple `LanguageModel`
/// (iOS 27) — the requirement for taking part in the `preferred()` bridge.
/// Custom `ModelProvider`s may adopt it to join; providers that don't are
/// simply skipped by `preferred()`.
@available(iOS 27.0, macOS 27.0, *)
public protocol LanguageModelConvertible {
    /// The native model, or `nil` when the provider cannot produce one right
    /// now (e.g. Private Cloud Compute in a process without the entitlement).
    var languageModel: (any LanguageModel)? { get }
}

@available(iOS 27.0, macOS 27.0, *)
extension OnDeviceProvider: LanguageModelConvertible {
    /// The system model itself — the same value the framework uses when no
    /// model is specified.
    public var languageModel: (any LanguageModel)? {
        SystemLanguageModel.default
    }
}
