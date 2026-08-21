//
//  AIPlaygroundView.swift
//  VoltaSDKUI
//
//  Ready-to-use prompt→response view, showing which provider answered and
//  at which privacy level.
//
//  Demonstrates the D12 pattern ("stateless core, transcript-transparent"):
//  this view plays the DEVELOPER's role — it owns the conversation history
//  and passes it on every call via `history:`. The framework stores
//  nothing; every call is self-contained, so follow-ups keep working even
//  if the provider changes between turns.
//

import SwiftUI
import VoltaSDK

/// A single prompt → response exchange, with provenance. `response` is
/// mutable so a streamed answer can grow in place (D16).
public struct PlaygroundExchange: Identifiable, Sendable {
    public let id = UUID()
    public let prompt: String
    public var response: AIResponse
}

/// Minimal playground the developer can use as-is or as a reference for
/// their own UI (all the logic goes through `streamDetailed`: fragments
/// render as they arrive, and provenance comes from the `.began` event).
public struct AIPlaygroundView: View {
    private let orchestrator: AIOrchestrator
    private let instructions: String?
    private let placeholder: String

    @State private var prompt = ""
    @State private var exchanges: [PlaygroundExchange] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var contextUsage: ContextUsage?

    public init(
        orchestrator: AIOrchestrator,
        instructions: String? = nil,
        placeholder: String = "Write a prompt…"
    ) {
        self.orchestrator = orchestrator
        self.instructions = instructions
        self.placeholder = placeholder
    }

    /// The history that will travel with the next turn ("developer" role).
    private var conversationHistory: [ChatTurn] {
        exchanges.flatMap { exchange in
            [.user(exchange.prompt), .assistant(exchange.response.text)]
        }
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Conversation (\(exchanges.count) turns)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let contextUsage {
                    // Pressure on the window of the provider that would
                    // answer next (D13): the signal to trim/summarize (D12).
                    Text("· context \(Int(contextUsage.fraction * 100))% of \(contextUsage.contextSize)")
                        .font(.caption)
                        .foregroundStyle(contextUsage.fraction > 0.8 ? .orange : .secondary)
                }
                Spacer()
                Button("New conversation", systemImage: "plus.bubble") {
                    exchanges.removeAll()
                    errorText = nil
                    contextUsage = nil
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(exchanges.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(exchanges) { exchange in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(exchange.prompt)
                                    .font(.body.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 6) {
                                    Text(exchange.response.provider.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    PrivacyLevelBadge(level: exchange.response.privacyLevel)
                                }
                                Text(exchange.response.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .id(exchange.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: exchanges.count) {
                    if let last = exchanges.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(isLoading || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        prompt = ""
        errorText = nil
        isLoading = true

        // Snapshot the history BEFORE the call: the app (here, the view)
        // owns and supplies it — the framework remembers nothing (D12).
        let history = conversationHistory

        Task {
            var provider: ProviderIdentifier?
            var privacy: PrivacyLevel?
            var streamed = ""
            do {
                for try await event in await orchestrator.streamDetailed(
                    to: text,
                    instructions: instructions,
                    history: history
                ) {
                    switch event {
                    case .began(let id, let level):
                        provider = id
                        privacy = level
                        exchanges.append(PlaygroundExchange(
                            prompt: text,
                            response: AIResponse(text: "", provider: id, privacyLevel: level)
                        ))
                    case .text(let fragment):
                        streamed += fragment
                        if let provider, let privacy, let index = exchanges.indices.last {
                            exchanges[index].response = AIResponse(
                                text: streamed, provider: provider, privacyLevel: privacy
                            )
                        }
                    }
                }
                contextUsage = await orchestrator.contextUsage(
                    instructions: instructions,
                    history: conversationHistory
                )
            } catch let error as ProviderError {
                // A mid-stream failure keeps the partial text on screen (D16:
                // shown text is never retracted) and surfaces the error.
                errorText = Self.describe(error)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

    private static func describe(_ error: ProviderError) -> String {
        switch error {
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limit reached, retry in \(Int(retryAfter))s"
            }
            return "Rate limit reached"
        case .unauthorized:
            return "Invalid or missing API key"
        case .network(let code):
            return "Network error (\(code))"
        case .emptyResponse:
            return "Empty response from the provider"
        case .encoding(let detail), .decoding(let detail):
            return "Data error: \(detail)"
        case .api(let message, _):
            return "Provider error: \(message)"
        case .contextWindowExceeded:
            return "Prompt too long for the context window"
        case .guardrailViolation:
            return "Content blocked by safety guardrails"
        case .unsupportedLanguage:
            return "Language not supported by the model"
        case .generation(let detail):
            return "Generation error: \(detail)"
        case .noProviderAvailable:
            return "No provider available"
        case .privacyRestricted:
            return "Blocked by the privacy policy"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
