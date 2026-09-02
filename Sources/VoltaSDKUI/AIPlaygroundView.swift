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

/// An app-supplied alternate driver for the playground (D1): the app decides
/// what answers — e.g. a native Dynamic Profile session fed by
/// `orchestrator.preferred()` on iOS 27 — and the playground renders its
/// events exactly like the built-in chain's. When present, a driver picker
/// appears and the SAME conversation continues across both drivers: the
/// history is app-owned (D12), so it replays into either engine.
public struct PlaygroundEngine: Sendable {
    /// Segment title in the driver picker (e.g. "Dynamic Profile").
    public var label: String
    /// Optional caption shown while this engine is selected.
    public var footnote: String?
    /// Streams a reply for the prompt + app-owned history, in the same
    /// event vocabulary as `AIOrchestrator.streamDetailed`.
    public var stream: @Sendable (
        _ prompt: String,
        _ instructions: String?,
        _ history: [ChatTurn]
    ) -> AsyncThrowingStream<AIStreamEvent, Error>

    public init(
        label: String,
        footnote: String? = nil,
        stream: @escaping @Sendable (
            _ prompt: String,
            _ instructions: String?,
            _ history: [ChatTurn]
        ) -> AsyncThrowingStream<AIStreamEvent, Error>
    ) {
        self.label = label
        self.footnote = footnote
        self.stream = stream
    }
}

/// Minimal playground the developer can use as-is or as a reference for
/// their own UI (all the logic goes through `streamDetailed`: fragments
/// render as they arrive, and provenance comes from the `.began` event).
public struct AIPlaygroundView: View {
    private let orchestrator: AIOrchestrator
    private let instructions: String?
    private let placeholder: String
    private let alternateEngine: PlaygroundEngine?

    @State private var prompt = ""
    @State private var exchanges: [PlaygroundExchange] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var contextUsage: ContextUsage?
    @State private var usesAlternateEngine = false
    /// Per-call need (D7) applied to the next message on the chain driver.
    @State private var need: ModelNeed?
    /// Live preview of the chain order the current need would walk (D7):
    /// phase 1 of the resolution, visible before sending. Unavailable
    /// providers appear in parentheses — phase 2 will skip them.
    @State private var chainPreview = ""

    public init(
        orchestrator: AIOrchestrator,
        instructions: String? = nil,
        placeholder: String = "Write a prompt…",
        alternateEngine: PlaygroundEngine? = nil
    ) {
        self.orchestrator = orchestrator
        self.instructions = instructions
        self.placeholder = placeholder
        self.alternateEngine = alternateEngine
    }

    /// The history that will travel with the next turn ("developer" role).
    private var conversationHistory: [ChatTurn] {
        exchanges.flatMap { exchange in
            [.user(exchange.prompt), .assistant(exchange.response.text)]
        }
    }

    /// Identity for the chain-preview task: recompute when the need or the
    /// orchestrator instance changes.
    private struct PreviewKey: Hashable {
        let need: ModelNeed?
        let orchestrator: ObjectIdentifier
    }

    public var body: some View {
        content
            .task(id: PreviewKey(need: need, orchestrator: ObjectIdentifier(orchestrator))) {
                await refreshChainPreview()
            }
    }

    private var content: some View {
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

            // Per-call need (D7): reorders the chain for the next message.
            // Applies to the chain driver; an alternate engine resolves its
            // own way, so the control is disabled there.
            HStack(spacing: 8) {
                Text("Need")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Need", selection: $need) {
                    Text("Auto").tag(ModelNeed?.none)
                    Text("Lightweight").tag(ModelNeed?.some(.lightweight))
                    Text("Reasoning").tag(ModelNeed?.some(.reasoning))
                    Text("Large context").tag(ModelNeed?.some(.largeContext))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(usesAlternateEngine)
            .opacity(usesAlternateEngine ? 0.5 : 1)

            if !chainPreview.isEmpty, !usesAlternateEngine {
                Text("Chain: \(chainPreview)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Driver picker (only when the app supplied an alternate engine):
            // the same conversation continues across both drivers — the
            // history is app-owned (D12), so it replays into either.
            if let alternateEngine {
                Picker("Driver", selection: $usesAlternateEngine) {
                    Text("VoltaSDK chain").tag(false)
                    Text(alternateEngine.label).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if usesAlternateEngine, let footnote = alternateEngine.footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    /// Recomputed when the need or the orchestrator changes, and after each
    /// exchange (availability can shift between turns — quota, keys).
    private func refreshChainPreview() async {
        let statuses = await orchestrator.providerStatuses(for: need)
        chainPreview = statuses
            .map { status in
                if case .available = status.availability {
                    return status.identifier.rawValue
                }
                return "(\(status.identifier.rawValue))"
            }
            .joined(separator: " → ")
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
                let events: AsyncThrowingStream<AIStreamEvent, Error>
                if usesAlternateEngine, let alternateEngine {
                    events = alternateEngine.stream(text, instructions, history)
                } else {
                    events = await orchestrator.streamDetailed(
                        to: text,
                        instructions: instructions,
                        history: history,
                        need: need
                    )
                }
                for try await event in events {
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
            await refreshChainPreview()   // availability may have shifted
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
