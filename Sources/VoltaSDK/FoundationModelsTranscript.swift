//
//  FoundationModelsTranscript.swift
//  VoltaSDK
//
//  Shared construction of a native Foundation Models `Transcript` from the
//  app-supplied conversation history (D12).
//
//  Every provider backed by an Apple `LanguageModel` rebuilds the same
//  transcript shape: on-device today, Private Cloud Compute on iOS 27, and
//  any future system-hosted model. Keeping the mapping in one place means the
//  model always sees the conversation exactly the same way, regardless of
//  which Apple backend answers.
//
//  PUBLIC because it is also the app-side glue between the two consumption
//  modes (D1/D12): an app that keeps a `[ChatTurn]` history for the
//  orchestrator can replay the same conversation into a native Dynamic
//  Profile via `LanguageModelSession(profile:history: entries(...))`.
//

import Foundation
import FoundationModels

public enum FoundationModelsTranscript {

    /// Maps instructions + history (D12) into native `Transcript` entries —
    /// usable as the `history:` of a `LanguageModelSession`, including one
    /// built from a Dynamic Profile (pass `instructions: nil` there: the
    /// profile owns its own instructions).
    public static func entries(
        instructions: String?,
        history: [ChatTurn]
    ) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        if let instructions, !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )))
        }
        for turn in history {
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            }
        }
        return entries
    }

    // MARK: Inverse — native Transcript → app-facing shape

    /// The inverse of `entries`: decompose a native `Transcript` back into the
    /// `(instructions, history, prompt)` shape VoltaSDK providers consume. The
    /// trailing user turn is treated as the current prompt; everything before
    /// it is history. Used by the iOS 27 "front door" adapters that drive a
    /// VoltaSDK `ModelProvider` from inside a `LanguageModelExecutor`.
    static func decompose(
        _ transcript: Transcript
    ) -> (instructions: String?, history: [ChatTurn], prompt: String) {
        var instructions: [String] = []
        var turns: [ChatTurn] = []
        for entry in transcript {
            switch entry {
            case .instructions(let i):
                instructions.append(text(of: i.segments))
            case .prompt(let p):
                turns.append(.user(text(of: p.segments)))
            case .response(let r):
                turns.append(.assistant(text(of: r.segments)))
            default:
                continue   // tool calls / outputs aren't modelled by ChatTurn
            }
        }
        var prompt = ""
        if let lastUser = turns.lastIndex(where: { $0.role == .user }) {
            prompt = turns[lastUser].text
            turns.remove(at: lastUser)
        }
        let joined = instructions
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined.isEmpty ? nil : joined, turns, prompt)
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.reduce(into: "") { result, segment in
            if case .text(let textSegment) = segment {
                result += textSegment.content
            }
        }
    }
}
