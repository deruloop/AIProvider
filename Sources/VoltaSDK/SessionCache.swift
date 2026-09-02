//
//  SessionCache.swift
//  VoltaSDK
//
//  D17: transparent warm-session reuse for the session-backed providers
//  (on-device, PCC, wrapped `LanguageModel`s). Rebuilding a session per call
//  (D12) re-processes the whole conversation prefix on every turn; when
//  consecutive calls continue the SAME conversation on the SAME provider,
//  the warm session already contains the history and only the new prompt
//  needs processing — matching a natively held Apple session.
//
//  Reuse rule: a call may reuse the cached session iff its (instructions,
//  history) EXACTLY equals the conversation the session has absorbed — the
//  history it was built with plus every exchange completed since. Any
//  divergence (the app trimmed or edited history, different instructions,
//  another conversation) is a miss: the entry is discarded and the call
//  builds fresh — exactly the pre-D17 behaviour. D12 stays intact: the app
//  still owns the history; the cache verifies continuation, never assumes it.
//
//  Errors never check back in: a session whose transcript may be
//  inconsistent (mid-stream failure included) must not be reused.
//
//  Exclusivity: `checkOut` REMOVES the entry, so concurrent calls can never
//  share one session — the loser of the race builds fresh. `@unchecked
//  Sendable` is sound because the Mutex guards the storage and a checked-out
//  session is exclusively owned by one call at a time.
//

import Foundation
import FoundationModels
import Synchronization

final class SessionCache: @unchecked Sendable {

    private struct Entry {
        let session: LanguageModelSession
        let instructions: String?
        let history: [ChatTurn]
    }

    private let entry = Mutex<Entry?>(nil)

    init() {}

    /// The warm session for exactly this conversation state, or `nil`.
    /// Always empties the cache: a hit transfers ownership to the caller,
    /// a miss discards the stale entry.
    func checkOut(instructions: String?, history: [ChatTurn]) -> LanguageModelSession? {
        entry.withLock { stored in
            defer { stored = nil }
            guard let candidate = stored,
                  candidate.instructions == instructions,
                  candidate.history == history else { return nil }
            return candidate.session
        }
    }

    /// Stores the session after a successful turn, together with the
    /// conversation it now contains (prior history + the new exchange).
    func checkIn(
        _ session: LanguageModelSession,
        instructions: String?,
        history: [ChatTurn]
    ) {
        entry.withLock {
            $0 = Entry(session: session, instructions: instructions, history: history)
        }
    }
}
