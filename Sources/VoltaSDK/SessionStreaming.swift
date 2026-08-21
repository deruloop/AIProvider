//
//  SessionStreaming.swift
//  VoltaSDK
//
//  Shared streaming plumbing for the session-backed providers (on-device,
//  PCC, and the iOS 27 `LanguageModelProvider` wrapper) — D16.
//
//  Foundation Models' `streamResponse` delivers CUMULATIVE partial snapshots
//  of the answer; VoltaSDK's streaming surface speaks in deltas (each fragment
//  is new text). This helper runs the session stream and converts snapshots to
//  deltas, leaving error mapping to the caller because each provider maps to
//  `ProviderError` from a different native error type.
//

import Foundation
import FoundationModels

enum SessionStreaming {
    /// Streams `prompt` through a session built by `makeSession`, converting
    /// cumulative snapshots to text deltas. Errors pass through `mapError`
    /// so each provider keeps its own native → `ProviderError` mapping.
    static func stream(
        prompt: String,
        makeSession: @escaping @Sendable () -> LanguageModelSession,
        mapError: @escaping @Sendable (any Error) -> any Error
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession()
                    var delivered = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let full = partial.content
                        // Plain-text snapshots are append-only; anything else
                        // (equal or non-extending) is skipped rather than
                        // risking duplicated text.
                        guard full.hasPrefix(delivered), full.count > delivered.count else {
                            continue
                        }
                        let delta = String(full.dropFirst(delivered.count))
                        delivered = full
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A stream that fails immediately — for guards before any work starts.
    static func failing(_ error: ProviderError) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
