//
//  ProfileEngine.swift
//  VoltaSDKDemoUI
//
//  The demo's alternate playground driver (Part 3): a NATIVE Apple
//  `DynamicProfile` — declared entirely in Apple's language — whose model is
//  the one VoltaSDK resolved (`orchestrator.preferred()`, re-run per turn,
//  D7). The SAME conversation continues across both drivers: the app-owned
//  `[ChatTurn]` history (D12) replays into the profile's session via the
//  public `FoundationModelsTranscript.entries`.
//
//  Two Swift 6 notes carried over from the first build of this feature:
//  resolve-then-declare (`preferred()` is async, profile modifiers aren't),
//  and the session's `sending profile:` parameter rejects profiles declared
//  in @MainActor context (isolation inheritance) — hence the nonisolated
//  session factory.
//

import Foundation
import VoltaSDK
import VoltaSDKUI
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
enum ProfileEngine {

    static func make(orchestrator: AIOrchestrator) -> PlaygroundEngine {
        PlaygroundEngine(
            label: "Dynamic Profile",
            footnote: "Apple's machinery drives: a native DynamicProfile (instructions + temperature in Apple's API). VoltaSDK contributes one expression — .model(orchestrator.preferred()) — re-resolved every turn. No mid-turn fallback here: that lives in the VoltaSDK chain driver."
        ) { prompt, _, history in
            stream(prompt: prompt, history: history, orchestrator: orchestrator)
        }
    }

    private static func stream(
        prompt: String,
        history: [ChatTurn],
        orchestrator: AIOrchestrator
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // VoltaSDK's one contribution: WHICH model (per turn, D7).
                    let model = try await orchestrator.preferred()
                    let provenance = try? await orchestrator.resolveProvider()

                    // From here on: 100% Apple's API.
                    let session = makeSession(model: model, history: history)
                    var delivered = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let full = partial.content
                        guard full.hasPrefix(delivered), full.count > delivered.count else {
                            continue
                        }
                        // Provenance rides ahead of the first fragment, like
                        // the chain driver's `.began` (D16 semantics).
                        if delivered.isEmpty, let provenance {
                            continuation.yield(.began(
                                provider: provenance.identifier,
                                privacyLevel: provenance.privacyLevel
                            ))
                        }
                        let delta = String(full.dropFirst(delivered.count))
                        delivered = full
                        continuation.yield(.text(delta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// NONISOLATED on purpose: the session's `profile:` parameter is
    /// `sending`, and a profile declared in @MainActor context inherits the
    /// actor's isolation through its instructions closure and cannot be sent.
    /// The profile owns its instructions; the app-owned history (D12) replays
    /// through the session's `history:` slot.
    private nonisolated static func makeSession(
        model: any LanguageModel,
        history: [ChatTurn]
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("You are a helpful, concise assistant.")
            }
            .model(model)
            .temperature(0.4),
            history: FoundationModelsTranscript.entries(instructions: nil, history: history)
        )
    }
}
