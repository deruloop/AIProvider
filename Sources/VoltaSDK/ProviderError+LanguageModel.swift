//
//  ProviderError+LanguageModel.swift
//  VoltaSDK
//
//  Shared mapping from the framework's `LanguageModelError` (iOS 27) onto
//  VoltaSDK's `ProviderError`, used by every provider that drives an Apple
//  `LanguageModel` through a session — Private Cloud Compute and the
//  user-account front door. One place so the recoverable/terminal split stays
//  consistent across them.
//

import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
extension ProviderError {
    /// Translates a `LanguageModelError` for the orchestrator: recoverable for
    /// context/rate/language/timeout (the chain can try another provider),
    /// terminal for guardrail/refusal, generic otherwise.
    init(_ error: LanguageModelError) {
        switch error {
        case .contextSizeExceeded:
            self = .contextWindowExceeded
        case .rateLimited(let info):
            self = .rateLimited(retryAfter: info.resetDate.map { $0.timeIntervalSinceNow })
        case .guardrailViolation, .refusal:
            self = .guardrailViolation(error.localizedDescription)
        case .unsupportedLanguageOrLocale:
            self = .unsupportedLanguage
        case .timeout:
            self = .network(code: -1)
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
            self = .generation(String(describing: error))
        @unknown default:
            self = .generation(String(describing: error))
        }
    }
}
