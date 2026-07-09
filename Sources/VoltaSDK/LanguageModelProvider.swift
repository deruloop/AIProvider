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
        let session: LanguageModelSession
        if history.isEmpty {
            session = LanguageModelSession(model: model, instructions: instructions)
        } else {
            let entries = FoundationModelsTranscript.entries(
                instructions: instructions, history: history
            )
            session = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
        }

        do {
            let response = try await session.respond(to: prompt)
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
}
