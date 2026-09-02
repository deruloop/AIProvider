//
//  LanguageModelProvider.swift
//  VoltaSDK
//
//  Adapts any Apple `LanguageModel` (iOS 27) into a VoltaSDK `ModelProvider`,
//  so it can take part in the orchestrator's fallback chain alongside the
//  on-device, PCC, and developer-key providers. It drives the model through a
//  `LanguageModelSession` — the same way the on-device and PCC providers do —
//  rebuilding the conversation as a native `Transcript` per call (D12).
//
//  This is what puts a user-account vendor (built as a
//  `CloudAccountLanguageModel`) into the chain: the orchestrator calls
//  `respond`, which runs a session, which drives our executor, which calls the
//  REST client. The same `LanguageModel` value is also what the iOS 27
//  `preferred(_:)` Dynamic Profiles bridge will hand back (next milestone).
//
//  Note: for a VoltaSDK-native cloud provider this routes the conversation
//  VoltaSDK → Transcript → executor → back to VoltaSDK's shape, a translation
//  round-trip the developer-key path avoids. It's the cost of going through
//  the public "front door" uniformly; acceptable while the surface stabilises.
//

import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
struct LanguageModelProvider: ModelProvider {

    let identifier: ProviderIdentifier
    let privacyLevel: PrivacyLevel

    /// Existential on purpose: this wrapper serves both VoltaSDK's own
    /// `CloudAccountLanguageModel` and vendor-shipped models plugged in via
    /// `AIConfiguration.customModels` (`LanguageModelSession(model:)` opens
    /// the existential at the call site).
    private let model: any LanguageModel
    /// Whether the backing credential/account is present. A LanguageModel has
    /// no generic availability notion, so the builder supplies it (for a
    /// user-account model: "is a key/token connected").
    private let connected: Bool
    /// Warm-session reuse (D17) — see `SessionCache`. For REST-backed models
    /// the wire cost is unchanged (HTTP chat APIs are stateless), but a
    /// vendor package with real native state benefits fully.
    private let sessionCache = SessionCache()

    init(
        identifier: ProviderIdentifier,
        privacyLevel: PrivacyLevel,
        model: any LanguageModel,
        connected: Bool
    ) {
        self.identifier = identifier
        self.privacyLevel = privacyLevel
        self.model = model
        self.connected = connected
    }

    func availability() async -> ProviderAvailability {
        connected ? .available : .unavailable(reason: "Account not connected")
    }

    func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        // Warm-session reuse (D17), else rebuilt from app-supplied history (D12).
        let session = sessionCache.checkOut(instructions: instructions, history: history)
            ?? makeSession(instructions: instructions, history: history)

        do {
            let response = try await session.respond(to: prompt)
            sessionCache.checkIn(
                session,
                instructions: instructions,
                history: history + [.user(prompt), .assistant(response.content)]
            )
            return response.content
        } catch let error as ProviderError {
            throw error                              // already our shape
        } catch let error as LanguageModelError {
            throw ProviderError(error)               // shared mapping
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch {
            throw ProviderError.generation(String(describing: error))
        }
    }

    // MARK: Streaming (D16)

    /// Native token streaming via the session's `streamResponse` (shared
    /// helper: cumulative snapshots → deltas). The wrapped model streams at
    /// whatever grain its executor emits — a vendor package with real deltas
    /// streams for real; a single-fragment executor delivers one delta.
    func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        let makeSession: @Sendable () -> LanguageModelSession = { [self] in
            self.makeSession(instructions: instructions, history: history)
        }
        return SessionStreaming.stream(
            prompt: prompt,
            instructions: instructions,
            history: history,
            cache: sessionCache,
            makeSession: makeSession,
            mapError: { error in
                if let provider = error as? ProviderError { return provider }
                if let framework = error as? LanguageModelError { return ProviderError(framework) }
                if error is CancellationError { return ProviderError.cancelled }
                return ProviderError.generation(String(describing: error))
            }
        )
    }

    /// Session construction shared by both paths (D12: stateless per call).
    private func makeSession(
        instructions: String?,
        history: [ChatTurn]
    ) -> LanguageModelSession {
        guard !history.isEmpty else {
            return LanguageModelSession(model: model, instructions: instructions)
        }
        let entries = FoundationModelsTranscript.entries(
            instructions: instructions, history: history
        )
        return LanguageModelSession(model: model, transcript: Transcript(entries: entries))
    }
}

// MARK: - Dynamic Profiles bridge (D1)

@available(iOS 27.0, macOS 27.0, *)
extension LanguageModelProvider: LanguageModelConvertible {
    /// The wrapped model, returned as-is: for user accounts that's the
    /// `CloudAccountLanguageModel`, for `customModels` the vendor's own
    /// conformance — exactly the value a Dynamic Profile should receive.
    var languageModel: (any LanguageModel)? { model }
}
