//
//  PrivateCloudComputeProvider.swift
//  VoltaSDK
//
//  Private Cloud Compute (iOS 27): a large, Apple-hosted model that integrates
//  like the on-device one — no key, no account — but runs in Apple's Private
//  Cloud Compute. It is the "free powered" tier (design decision D6): free for
//  the developer (apps under 2M downloads, with the PCC entitlement), with a
//  per-user DAILY QUOTA that can run out mid-use.
//
//  Two consequences shape this provider:
//   - Privacy is `.appleCloud`: above an external vendor, below on-device.
//     Reaching it during fallback is a privacy downgrade and goes through the
//     normal disclosure policy (D7/D10).
//   - Quota is the main reason fallback must be RUNTIME, not a static setup
//     choice. iOS 27 exposes the remaining quota PROACTIVELY
//     (`quotaUsage`/`isLimitReached`), so `availability()` can skip an
//     exhausted PCC before paying for a doomed call, AND it surfaces a
//     distinct `.quotaLimitReached` error if the quota runs out mid-call —
//     mapped to a recoverable `.rateLimited` so the chain steps down.
//
//  iOS 27 only: gated `@available` at the type level (D14). On iOS 26 the
//  type does not exist and `buildProviders` simply never creates it.
//

import Foundation
import FoundationModels
import Security

@available(iOS 27.0, macOS 27.0, *)
public struct PrivateCloudComputeProvider: ModelProvider {

    public let identifier = ProviderIdentifier.privateCloudCompute
    public let privacyLevel = PrivacyLevel.appleCloud

    /// The Apple-granted entitlement a process must carry to call PCC. Without
    /// it the framework **traps** (a fatal error, not a catchable Swift error)
    /// on the first generation — see the comment on `availability()`.
    public static let requiredEntitlement = "com.apple.developer.private-cloud-compute"

    /// One model instance — but ONLY in an entitled process (`nil` otherwise).
    ///
    /// The entitlement gate lives at CONSTRUCTION, not just at the call sites.
    /// Observed on macOS 27 (beta 27A5209h), in a long-running unentitled app:
    /// merely instantiating `PrivateCloudComputeLanguageModel` spins up
    /// background status machinery ("Failed to check usage limit status",
    /// "establishment of session failed with Missing entitlement") that
    /// eventually TRAPS on a background thread (EXC_BREAKPOINT) — a crash no
    /// call-site guard can intercept, because our code isn't on the stack.
    /// The entitlement is baked into the code signature and cannot change at
    /// runtime, so deciding once at init is sound: unentitled → never create
    /// the model → the provider reports unavailable and the chain skips it.
    private let model: PrivateCloudComputeLanguageModel?

    public init() {
        self.model = Self.hasRequiredEntitlement() ? PrivateCloudComputeLanguageModel() : nil
    }

    public func availability() async -> ProviderAvailability {
        // Entitlement gate (decided at init — see `model`). Also verified: an
        // unentitled process does NOT see `model.availability` change — it
        // still reports `.available` — but the first `respond` traps with
        //   "Process is missing required entitlement: com.apple.developer.private-cloud-compute"
        // a fatal error `do/catch` cannot intercept. Since PCC is default-on,
        // the missing entitlement must degrade to a graceful skip, never a call.
        guard let model else {
            return .unavailable(reason: "Missing the \(Self.requiredEntitlement) entitlement")
        }
        switch model.availability {
        case .available:
            // Proactive quota pre-check (Q1, answered by the iOS 27 SDK):
            // an exhausted daily quota makes PCC effectively unavailable until
            // its reset, so the chain skips it without a doomed round-trip.
            if model.quotaUsage.isLimitReached {
                return .unavailable(reason: Self.quotaReason(model.quotaUsage))
            }
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Private Cloud Compute unavailable")
        }
    }

    /// Whether the running process is signed with the PCC entitlement. Reads
    /// the binary's own entitlements via the Security framework; no special
    /// permission needed. Returns false when absent (the common case), so the
    /// provider skips itself rather than trapping.
    static func hasRequiredEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, requiredEntitlement as CFString, nil)
        if let flag = value as? Bool { return flag }
        return value != nil
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        // Unentitled process → the model was never created (see `model`).
        // Recoverable: the chain moves on. (The orchestrator won't normally
        // reach here — availability() already reported unavailable — but a
        // direct caller must not trap either.)
        guard let model else { throw ProviderError.noProviderAvailable }

        // Stateless per call (D12): the app-supplied history is rebuilt as a
        // native Transcript so PCC sees the conversation as its own — the same
        // shape the on-device provider uses.
        let session = Self.makeSession(
            model: model, instructions: instructions, history: history
        )

        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            throw Self.map(error)
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
    /// helper: cumulative snapshots → deltas). Same entitlement guard and
    /// error mapping as the buffered path.
    public func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        guard let model else { return SessionStreaming.failing(.noProviderAvailable) }
        return SessionStreaming.stream(
            prompt: prompt,
            makeSession: { Self.makeSession(model: model, instructions: instructions, history: history) },
            mapError: { error in
                if let pcc = error as? PrivateCloudComputeLanguageModel.Error {
                    return Self.map(pcc)
                }
                if let framework = error as? LanguageModelError {
                    return ProviderError(framework)
                }
                if error is CancellationError { return ProviderError.cancelled }
                return ProviderError.generation(String(describing: error))
            }
        )
    }

    /// Session construction shared by `respond` and `streamResponse` (D12:
    /// stateless per call, app-supplied history rebuilt as a Transcript).
    private static func makeSession(
        model: PrivateCloudComputeLanguageModel,
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

    // MARK: Token awareness (D13)
    //
    // PCC exposes `contextSize` as `async throws`, which does not fit the
    // synchronous `ModelProvider.contextSize` surface (D13 assumed a cheap
    // synchronous read, true for the on-device model). Rather than block on it,
    // PCC opts out of the proactive pre-flight and relies on the reactive
    // `.contextWindowExceeded` path (consistent with D7: the crossing is driven
    // by measured overflow). Generalizing D13 to an async context read is a
    // tracked follow-up. Until then `contextSize`/`tokenCount` stay `nil` (the
    // protocol defaults).

    // MARK: Error mapping

    /// Maps PCC-specific errors. The whole point of PCC's distinct error enum
    /// (Q2/Q4, answered by the SDK) is that quota exhaustion is separable from
    /// a transient outage:
    ///  - `.quotaLimitReached` → recoverable `.rateLimited`; `resetDate` (Q3)
    ///    becomes `retryAfter` so the chain (and UI) know when PCC returns.
    ///  - `.serviceUnavailable` / `.networkFailure` → recoverable network class:
    ///    PCC is temporarily down, not the user's quota — still worth falling
    ///    through, but it is not a quota event.
    static func map(_ error: PrivateCloudComputeLanguageModel.Error) -> ProviderError {
        switch error {
        case .quotaLimitReached(let info):
            return .rateLimited(retryAfter: info.resetDate.map { $0.timeIntervalSinceNow })
        case .serviceUnavailable:
            return .network(code: -1)
        case .networkFailure:
            return .network(code: -1)
        @unknown default:
            return .generation(String(describing: error))
        }
    }

    private static func describe(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Private Cloud Compute"
        case .systemNotReady:
            return "Private Cloud Compute is not ready yet"
        @unknown default:
            return "Private Cloud Compute unavailable"
        }
    }

    private static func quotaReason(
        _ usage: PrivateCloudComputeLanguageModel.QuotaUsage
    ) -> String {
        if let reset = usage.resetDate {
            return "Private Cloud Compute daily quota reached (resets \(reset))"
        }
        return "Private Cloud Compute daily quota reached"
    }
}
