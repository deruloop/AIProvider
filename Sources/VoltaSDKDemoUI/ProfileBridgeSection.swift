//
//  ProfileBridgeSection.swift
//  VoltaSDKDemoUI
//
//  Demo of the Dynamic Profiles bridge (D1): a NATIVE Apple `DynamicProfile`
//  — declared entirely in Apple's language — whose model is the one VoltaSDK
//  resolved (`orchestrator.preferred()`). VoltaSDK contributes exactly one
//  expression; the instructions, temperature, session, and streaming are the
//  framework's own declarative API.
//
//  Note the resolve-then-declare shape: `preferred()` is async (it runs the
//  chain's availability checks), while a profile's modifiers are synchronous
//  — so the model is resolved first and the profile is declared around the
//  value. Per-call re-resolution (D7) is preserved by resolving inside `run`.
//

import SwiftUI
import VoltaSDK
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
struct ProfileBridgeSection: View {
    let orchestrator: AIOrchestrator

    @State private var prompt = ""
    @State private var answer = ""
    @State private var resolvedProvider: String?
    @State private var errorText: String?
    @State private var isRunning = false

    var body: some View {
        Section("Dynamic Profile (iOS 27)") {
            Text("A native Apple DynamicProfile — instructions and temperature declared in Apple's own API — whose model comes from the chain: .model(orchestrator.preferred()). Whatever is resolvable right now (on-device, PCC, a connected account) powers the profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Ask the profile…", text: $prompt)
                .onSubmit { run() }
            Button {
                run()
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run through the resolved model", systemImage: "sparkles")
                }
            }
            .disabled(isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let resolvedProvider {
                Text("Resolved to: \(resolvedProvider)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !answer.isEmpty {
                Text(answer)
                    .textSelection(.enabled)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func run() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        isRunning = true
        answer = ""
        errorText = nil
        resolvedProvider = nil

        Task {
            do {
                // VoltaSDK's one contribution: WHICH model. Resolved per run
                // (D7) — async, so before the declarative part.
                let model = try await orchestrator.preferred()
                if let provider = try? await orchestrator.resolveProvider() {
                    resolvedProvider = provider.identifier.rawValue
                }

                // From here on: 100% Apple's API, no VoltaSDK types.
                let session = Self.makeProfileSession(model: model)
                for try await partial in session.streamResponse(to: text) {
                    answer = partial.content        // cumulative snapshots
                }
            } catch let error as ProviderError {
                errorText = "Provider error: \(String(describing: error))"
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// Built in a NONISOLATED context on purpose. The session's `profile:`
    /// parameter is `sending` (the profile must be transferable), but a
    /// profile declared inside a @MainActor view silently inherits the actor's
    /// isolation through its instructions closure and can never leave that
    /// region — Swift 6's dynamic-isolation inheritance, the same lesson the
    /// OAuth completion handler taught in VoltaSDKAuth. Declaring the profile
    /// in a nonisolated function keeps its region disconnected.
    private nonisolated static func makeProfileSession(
        model: any LanguageModel
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: LanguageModelSession.Profile {
                Instructions("You are a concise assistant. Answer in at most two sentences.")
            }
            .model(model)
            .temperature(0.4)
        )
    }
}
