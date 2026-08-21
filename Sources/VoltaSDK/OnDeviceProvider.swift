//
//  OnDeviceProvider.swift
//  VoltaSDK
//
//  Wraps Apple Intelligence's on-device model (Foundation Models, iOS 26).
//  No network, no key, maximum privacy.
//

import Foundation
import FoundationModels

public struct OnDeviceProvider: ModelProvider {

    public let identifier = ProviderIdentifier.onDevice
    public let privacyLevel = PrivacyLevel.onDevice

    public init() {}

    public func availability() async -> ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Unknown unavailability reason")
        }
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        // A session is created per call (stateless, D12): the conversation
        // history comes from the app and is rebuilt as a native Foundation
        // Models Transcript.
        let session = Self.makeSession(instructions: instructions, history: history)

        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch {
            throw ProviderError.generation(String(describing: error))
        }
    }

    // MARK: Streaming (D16)

    /// Native token streaming via the session's `streamResponse`, with the
    /// framework's cumulative snapshots converted to deltas (shared helper).
    public func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        SessionStreaming.stream(
            prompt: prompt,
            makeSession: { Self.makeSession(instructions: instructions, history: history) },
            mapError: { error in
                if let generation = error as? LanguageModelSession.GenerationError {
                    return Self.map(generation)
                }
                if error is CancellationError { return ProviderError.cancelled }
                return ProviderError.generation(String(describing: error))
            }
        )
    }

    // MARK: Token awareness (D13)

    /// Context window of the on-device model. The property is back-deployed:
    /// available across all of 26.x.
    public var contextSize: Int? {
        SystemLanguageModel.default.contextSize
    }

    /// EXACT count via the SDK from iOS/macOS 26.4; `nil` on 26.0–26.3
    /// (the base tier stays reactive-only: error after the call).
    public func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? {
        guard #available(iOS 26.4, macOS 26.4, *) else { return nil }
        var entries = FoundationModelsTranscript.entries(instructions: instructions, history: history)
        if !prompt.isEmpty {
            entries.append(.prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: prompt))]
            )))
        }
        return try? await SystemLanguageModel.default.tokenCount(for: entries)
    }

    // MARK: Session/transcript construction

    /// Builds the session for a single call. Without history it uses the
    /// simple initializers; with history it rebuilds a native `Transcript`,
    /// so the model sees the conversation exactly as if it were its own.
    private static func makeSession(
        instructions: String?,
        history: [ChatTurn]
    ) -> LanguageModelSession {
        guard !history.isEmpty else {
            if let instructions, !instructions.isEmpty {
                return LanguageModelSession(instructions: instructions)
            }
            return LanguageModelSession()
        }
        let entries = FoundationModelsTranscript.entries(instructions: instructions, history: history)
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    /// Maps generation errors onto ProviderError, separating the cases the
    /// fallback can recover from (context window, language, rate limit) from
    /// the terminal ones (guardrail: we do not auto-forward content the
    /// system blocked to an external provider).
    private static func map(_ error: LanguageModelSession.GenerationError) -> ProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation:
            return .guardrailViolation(error.localizedDescription)
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .rateLimited:
            // On-device rate limit (e.g. app in background): falling back
            // to a cloud provider is legitimate.
            return .rateLimited(retryAfter: nil)
        default:
            return .generation(String(describing: error))
        }
    }

    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled in Settings"
        case .modelNotReady:
            return "The model is still downloading or not ready"
        @unknown default:
            return "On-device model unavailable"
        }
    }
}
