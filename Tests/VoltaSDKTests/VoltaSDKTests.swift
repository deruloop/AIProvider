//
//  VoltaSDKTests.swift
//  VoltaSDKTests
//

import Foundation
import Testing
import Synchronization
import FoundationModels
@testable import VoltaSDK
@testable import VoltaSDKAuth

// MARK: - Selection and fallback

@Suite("Orchestrator and fallback")
struct OrchestratorFallbackTests {

    @Test("Uses the first available provider")
    func usesFirstAvailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("on-device")),
            MockProvider(identifier: .openAI, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "hello")
        #expect(result == "on-device")
    }

    @Test("Skips an unavailable provider")
    func skipsUnavailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "no Apple Intelligence"),
                         outcome: .success("on-device")),
            MockProvider(identifier: .openAI, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "hello")
        #expect(result == "openai")
    }

    @Test("Falls back on rate limit")
    func fallsBackOnRateLimit() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.rateLimited(retryAfter: nil))),
            MockProvider(identifier: .onDevice, outcome: .success("on-device"))
        ])
        let result = try await kit.respond(to: "hello")
        #expect(result == "on-device")
    }

    @Test("Falls back on context-window overflow")
    func fallsBackOnContextWindow() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .failure(.contextWindowExceeded)),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "hello")
        #expect(result == "openai")
    }

    @Test("Does not fall back on a terminal error (auth)")
    func doesNotFallBackOnTerminalError() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.unauthorized)),
            MockProvider(identifier: .onDevice, outcome: .success("on-device"))
        ])
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("Does not fall back on a guardrail violation")
    func doesNotFallBackOnGuardrail() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .failure(.guardrailViolation("blocked"))),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        await #expect(throws: ProviderError.guardrailViolation("blocked")) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("Errors when the provider list is empty")
    func errorWhenEmpty() async {
        let kit = AIOrchestrator(providers: [])
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("Errors when every provider is unavailable")
    func errorWhenAllUnavailable() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI,
                         availability: .unavailable(reason: "y"),
                         outcome: .success("b"))
        ])
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("Reports the last error when every provider fails recoverably")
    func reportsLastRecoverableError() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.rateLimited(retryAfter: nil))),
            MockProvider(identifier: .onDevice, outcome: .failure(.network(code: -1009)))
        ])
        await #expect(throws: ProviderError.network(code: -1009)) {
            _ = try await kit.respond(to: "hello")
        }
    }
}

// MARK: - Detailed response and resolution

@Suite("Resolution and provenance")
struct ResolutionTests {

    @Test("respondDetailed reports provider and privacy level")
    func detailedResponseCarriesProvenance() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        let response = try await kit.respondDetailed(to: "hello")
        #expect(response.text == "openai")
        #expect(response.provider == .openAI)
        #expect(response.privacyLevel == .external)
    }

    @Test("resolveProvider returns the first available without executing")
    func resolveReturnsFirstAvailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
        ])
        let provider = try await kit.resolveProvider()
        #expect(provider.identifier == .openAI)
    }

    @Test("resolveProvider with denyDowngrade excludes providers below the threshold")
    func resolveRespectsDenyDowngrade() async {
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice,
                             privacyLevel: .onDevice,
                             availability: .unavailable(reason: "x"),
                             outcome: .success("a")),
                MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
            ],
            privacyDisclosure: .denyDowngrade
        )
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.resolveProvider()
        }
    }

    @Test("providerStatuses reports the whole chain in order, with reasons")
    func statusesReportWholeChain() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         privacyLevel: .onDevice,
                         availability: .unavailable(reason: "no Apple Intelligence"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
        ])
        let statuses = await kit.providerStatuses()
        #expect(statuses.count == 2)
        #expect(statuses[0].identifier == .onDevice)
        #expect(statuses[0].availability == .unavailable(reason: "no Apple Intelligence"))
        #expect(statuses[1].identifier == .openAI)
        #expect(statuses[1].availability == .available)
        #expect(statuses[1].privacyLevel == .external)
    }
}

// MARK: - Privacy disclosure

@Suite("Privacy disclosure")
struct PrivacyDisclosureTests {

    /// Chain: on-device (unavailable) → openai (external).
    /// The baseline is onDevice, so using openai is a downgrade.
    private func downgradeChain() -> [any ModelProvider] {
        [
            MockProvider(identifier: .onDevice,
                         privacyLevel: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ]
    }

    @Test("silent: the downgrade proceeds without any signal")
    func silentAllowsDowngrade() async throws {
        let kit = AIOrchestrator(providers: downgradeChain(), privacyDisclosure: .silent)
        #expect(try await kit.respond(to: "hello") == "openai")
    }

    @Test("notify: the downgrade proceeds and the handler receives the event")
    func notifyFiresHandler() async throws {
        let events = Mutex<[PrivacyDowngrade]>([])
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .notify { downgrade in
                events.withLock { $0.append(downgrade) }
            }
        )
        let result = try await kit.respond(to: "hello")
        #expect(result == "openai")

        let recorded = events.withLock { $0 }
        #expect(recorded == [
            PrivacyDowngrade(from: .onDevice, to: .external, provider: .openAI)
        ])
    }

    @Test("askOnPrivacyChange: true → proceeds")
    func askApprovedProceeds() async throws {
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .askOnPrivacyChange { _ in true }
        )
        #expect(try await kit.respond(to: "hello") == "openai")
    }

    @Test("askOnPrivacyChange: false → privacyRestricted")
    func askDeclinedBlocks() async {
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .askOnPrivacyChange { _ in false }
        )
        await #expect(throws: ProviderError.privacyRestricted) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("denyDowngrade: providers below the threshold are never used")
    func denyBlocksDowngrade() async {
        let kit = AIOrchestrator(providers: downgradeChain(), privacyDisclosure: .denyDowngrade)
        await #expect(throws: ProviderError.privacyRestricted) {
            _ = try await kit.respond(to: "hello")
        }
    }

    @Test("No downgrade when the answering provider matches the baseline level")
    func noDowngradeAtSameLevel() async throws {
        let events = Mutex<[PrivacyDowngrade]>([])
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice, privacyLevel: .onDevice, outcome: .success("on-device")),
                MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
            ],
            privacyDisclosure: .notify { downgrade in
                events.withLock { $0.append(downgrade) }
            }
        )
        let result = try await kit.respond(to: "hello")
        #expect(result == "on-device")
        #expect(events.withLock { $0 }.isEmpty)
    }
}

// MARK: - Transcript transparency (D12)

@Suite("Conversation history (D12)")
struct ConversationHistoryTests {

    @Test("App-supplied history reaches the provider intact")
    func historyReachesProvider() async throws {
        let received = Mutex<[ChatTurn]?>(nil)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("ok")) { _, _, history in
                received.withLock { $0 = history }
            }
        ])

        let history: [ChatTurn] = [
            .user("Plan a weekend"),
            .assistant("Here's the itinerary…")
        ]
        _ = try await kit.respond(to: "change day 2", history: history)

        #expect(received.withLock { $0 } == history)
    }

    @Test("Without history the provider receives an empty list")
    func defaultHistoryIsEmpty() async throws {
        let received = Mutex<[ChatTurn]?>(nil)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("ok")) { _, _, history in
                received.withLock { $0 = history }
            }
        ])
        _ = try await kit.respond(to: "hello")
        #expect(received.withLock { $0 } == [])
    }

    @Test("Fallback forwards the SAME history to the next provider")
    func fallbackForwardsSameHistory() async throws {
        let firstSaw = Mutex<[ChatTurn]?>(nil)
        let secondSaw = Mutex<[ChatTurn]?>(nil)

        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         outcome: .failure(.rateLimited(retryAfter: nil))) { _, _, history in
                firstSaw.withLock { $0 = history }
            },
            MockProvider(identifier: .openAI,
                         privacyLevel: .external,
                         outcome: .success("openai")) { _, _, history in
                secondSaw.withLock { $0 = history }
            }
        ])

        let history: [ChatTurn] = [.user("turn 1"), .assistant("answer 1")]
        let result = try await kit.respond(to: "turn 2", history: history)

        // The first provider fails recoverably; the second receives the
        // self-contained call with the same history: the conversation
        // survives the provider switch.
        #expect(result == "openai")
        #expect(firstSaw.withLock { $0 } == history)
        #expect(secondSaw.withLock { $0 } == history)
    }
}

// MARK: - Token awareness (D13)

@Suite("Token awareness (D13)")
struct TokenAwarenessTests {

    @Test("Pre-flight: skips a provider whose window is too small, without calling it")
    func preflightSkipsOverflowingProvider() async throws {
        let firstWasCalled = Mutex(false)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         contextSize: 100,
                         tokenCount: 200,
                         onRespond: { _, _, _ in firstWasCalled.withLock { $0 = true } }),
            MockProvider(identifier: .openAI,
                         privacyLevel: .external,
                         outcome: .success("openai"),
                         contextSize: 128_000,
                         tokenCount: 200)
        ])

        let result = try await kit.respond(to: "a long prompt")
        #expect(result == "openai")
        #expect(firstWasCalled.withLock { $0 } == false)
    }

    @Test("Pre-flight: the response reserve counts toward the budget")
    func preflightAccountsForResponseReserve() async throws {
        // 60 call tokens + 50 reserve > 100-token window → skip.
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice,
                             contextSize: 100,
                             tokenCount: 60),
                MockProvider(identifier: .openAI,
                             privacyLevel: .external,
                             outcome: .success("openai"))
            ],
            responseTokenReserve: 50
        )
        #expect(try await kit.respond(to: "x") == "openai")
    }

    @Test("Pre-flight: every window too small → contextWindowExceeded")
    func preflightThrowsWhenNothingFits() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, contextSize: 100, tokenCount: 500),
            MockProvider(identifier: .openAI, contextSize: 200, tokenCount: 500)
        ])
        await #expect(throws: ProviderError.contextWindowExceeded) {
            _ = try await kit.respond(to: "huge")
        }
    }

    @Test("A provider that can't count is never discarded by pre-flight")
    func providerWithoutCountingIsNotSkipped() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("on-device"))
            // contextSize/tokenCount nil → no pre-flight possible.
        ])
        #expect(try await kit.respond(to: "hello") == "on-device")
    }

    @Test("contextUsage reports tokens, window and resolved provider")
    func contextUsageReportsPressure() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, contextSize: 4096, tokenCount: 1024)
        ])
        let usage = await kit.contextUsage(history: [.user("a"), .assistant("b")])
        #expect(usage == ContextUsage(tokens: 1024, contextSize: 4096, provider: .onDevice))
        #expect(usage?.fraction == 0.25)
    }

    @Test("contextUsage is nil when the resolved provider can't count")
    func contextUsageNilWithoutCapability() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice)
        ])
        let usage = await kit.contextUsage(history: [])
        #expect(usage == nil)
    }

    @Test("OpenAI: known windows per model, nil for unknown models")
    func openAIKnownWindows() {
        #expect(OpenAIProvider.knownContextSize(forModel: "gpt-4o-mini") == 128_000)
        #expect(OpenAIProvider.knownContextSize(forModel: "gpt-4.1") == 1_047_576)
        #expect(OpenAIProvider.knownContextSize(forModel: "mystery-model") == nil)
    }

    @Test("OpenAI: the token estimate uses ~4 characters/token over the whole payload")
    func openAITokenEstimate() async {
        let provider = OpenAIProvider(apiKey: "test")
        let estimate = await provider.tokenCount(
            prompt: String(repeating: "a", count: 100),
            instructions: String(repeating: "b", count: 100),
            history: [.user(String(repeating: "c", count: 100)),
                      .assistant(String(repeating: "d", count: 100))]
        )
        #expect(estimate == 100)   // 400 characters / 4
    }
}

// MARK: - Multi-vendor developer key (D15)

@Suite("Cloud vendor detection (D15)")
struct CloudVendorTests {

    @Test("Key prefixes map to the right vendor")
    func detectsVendorFromKeyPrefix() {
        #expect(CloudVendor.detect(fromKey: "sk-ant-api03-abc") == .anthropic)
        #expect(CloudVendor.detect(fromKey: "AIzaSyD-abc") == .gemini)
        #expect(CloudVendor.detect(fromKey: "sk-proj-abc") == .openAI)
        #expect(CloudVendor.detect(fromKey: "sk-abc") == .openAI)
        #expect(CloudVendor.detect(fromKey: "mystery") == nil)
    }

    @Test("Detection tolerates pasted whitespace around the key")
    func detectionTrimsWhitespace() {
        // Observed live: a valid Gemini key pasted with a stray newline read
        // as "unknown format" and was routed to the wrong vendor.
        #expect(CloudVendor.detect(fromKey: " AIzaSyD-abc\n") == .gemini)
        #expect(CloudVendor.detect(fromKey: "\nsk-ant-api03-abc ") == .anthropic)
        #expect(CloudVendor.detect(fromKey: " sk-proj-abc") == .openAI)
    }

    @Test("Google's new AQ. Auth keys are detected as Gemini")
    func detectsNewGoogleAuthKeyFormat() {
        // Mid-2026 migration: AI Studio now issues only AQ.-prefix keys
        // (observed live — an adopter's fresh key read as "unknown format").
        #expect(CloudVendor.detect(fromKey: "AQ.Ab8RN6-abc") == .gemini)
    }

    @Test("Anthropic prefix wins over the OpenAI prefix it contains")
    func anthropicPrefixPrecedence() {
        // "sk-ant-…" also matches "sk-…": order must favor Anthropic.
        #expect(CloudVendor.detect(fromKey: "sk-ant-xyz") != .openAI)
    }

    @Test("The configuration builds the provider matching the key vendor")
    func buildsMatchingProvider() {
        var config = AIConfiguration()

        config.developerKey = "sk-ant-test"
        #expect(AIOrchestrator.buildCloudProvider(from: config)?.identifier == .anthropic)

        config.developerKey = "AIzaTest"
        #expect(AIOrchestrator.buildCloudProvider(from: config)?.identifier == .gemini)

        config.developerKey = "sk-test"
        #expect(AIOrchestrator.buildCloudProvider(from: config)?.identifier == .openAI)

        // Explicit vendor overrides detection.
        config.developerKeyVendor = .gemini
        #expect(AIOrchestrator.buildCloudProvider(from: config)?.identifier == .gemini)

        config.developerKey = nil
        config.developerKeyVendor = nil
        #expect(AIOrchestrator.buildCloudProvider(from: config) == nil)
    }

    @Test("Each vendor has a default model and documentation link")
    func vendorDefaults() {
        for vendor in CloudVendor.allCases {
            #expect(!vendor.defaultModel.isEmpty)
            #expect(vendor.modelDocumentationURL.scheme == "https")
        }
    }

    @Test("Anthropic: known windows per model, nil for unknown models")
    func anthropicKnownWindows() {
        #expect(AnthropicProvider.knownContextSize(forModel: "claude-opus-4-8") == 1_000_000)
        #expect(AnthropicProvider.knownContextSize(forModel: "claude-haiku-4-5") == 200_000)
        #expect(AnthropicProvider.knownContextSize(forModel: "mystery-model") == nil)
    }

    @Test("Gemini: known windows per model, nil for unknown models")
    func geminiKnownWindows() {
        #expect(GeminiProvider.knownContextSize(forModel: "gemini-3.6-flash") == 1_048_576)
        #expect(GeminiProvider.knownContextSize(forModel: "gemini-1.5-pro") == 2_097_152)
        #expect(GeminiProvider.knownContextSize(forModel: "mystery-model") == nil)
    }

    @Test("Gemini: thinking models get output headroom, older ones don't")
    func geminiThinkingHeadroom() {
        #expect(GeminiProvider.thinkingHeadroom(forModel: "gemini-3.6-flash") > 0)
        #expect(GeminiProvider.thinkingHeadroom(forModel: "gemini-2.5-flash") > 0)
        #expect(GeminiProvider.thinkingHeadroom(forModel: "gemini-1.5-pro") == 0)
        #expect(GeminiProvider.thinkingHeadroom(forModel: "gemini-2.0-flash") == 0)
    }

    @Test("Gemini: a textless answer names its cause")
    func geminiEmptyAnswerDiagnosis() {
        // Budget consumed by thinking — the failure this replaced.
        let budget = GeminiProvider.emptyAnswerError(
            finishReason: "MAX_TOKENS", blockReason: nil, thoughtTokens: 1000
        )
        guard case .api(let message, let code) = budget else {
            Issue.record("expected an API error, got \(budget)"); return
        }
        #expect(code == "MAX_TOKENS")
        #expect(message.contains("1000 tokens thinking"))

        // Policy stops are guardrail violations, not empty responses.
        if case .guardrailViolation = GeminiProvider.emptyAnswerError(
            finishReason: "SAFETY", blockReason: nil, thoughtTokens: nil
        ) {} else { Issue.record("SAFETY should map to a guardrail violation") }
        if case .guardrailViolation = GeminiProvider.emptyAnswerError(
            finishReason: nil, blockReason: "OTHER", thoughtTokens: nil
        ) {} else { Issue.record("a blocked prompt should map to a guardrail violation") }

        // A clean stop with no text really is an empty response.
        #expect(GeminiProvider.emptyAnswerError(
            finishReason: "STOP", blockReason: nil, thoughtTokens: nil
        ) == .emptyResponse)
    }

    @Test("Cloud providers are unavailable without a key")
    func unavailableWithoutKey() async {
        #expect(await AnthropicProvider(apiKey: "").availability()
            == .unavailable(reason: "API key not configured"))
        #expect(await GeminiProvider(apiKey: "").availability()
            == .unavailable(reason: "API key not configured"))
    }
}

// MARK: - Private Cloud Compute wiring (iOS 27)

@Suite("Private Cloud Compute (iOS 27)")
struct PrivateCloudComputeTests {

    @Test("Disabling PCC keeps it out of the chain, regardless of OS")
    func disabledMeansNoProvider() {
        var config = AIConfiguration()
        config.enablePrivateCloudCompute = false
        #expect(AIOrchestrator.buildPrivateCloudComputeProvider(from: config) == nil)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("Default config builds PCC with the .appleCloud privacy level")
    func defaultBuildsPCC() {
        let provider = AIOrchestrator.buildPrivateCloudComputeProvider(from: AIConfiguration())
        #expect(provider?.identifier == .privateCloudCompute)
        #expect(provider?.privacyLevel == .appleCloud)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("PCC joins the prefer chains but never the strict only modes")
    func chainMembership() async {
        func identifiers(_ preference: ModelPreference) async -> [ProviderIdentifier] {
            var config = AIConfiguration()
            config.preference = preference
            config.developerKey = "sk-test"   // ensure a cloud provider exists
            let statuses = await AIOrchestrator(configuration: config).providerStatuses()
            return statuses.map(\.identifier)
        }

        // Privacy order in the prefer-on-device chain: on-device → PCC → key.
        #expect(await identifiers(.preferOnDevice)
            == [.onDevice, .privateCloudCompute, .openAI])
        // Strict modes stay single-provider — PCC is a fallback tier, not a peer.
        #expect(await identifiers(.onDeviceOnly) == [.onDevice])
        #expect(await identifiers(.developerKeyOnly) == [.openAI])
    }
}

// MARK: - Transcript translation (iOS 27 front door)

@Suite("Transcript translation")
struct TranscriptTranslationTests {

    @Test("decompose inverts entries — the trailing user turn is the prompt")
    func roundTrip() {
        let history: [ChatTurn] = [.user("hi"), .assistant("hello"), .user("plan a trip")]
        let entries = FoundationModelsTranscript.entries(
            instructions: "Be concise.", history: history
        )
        let parts = FoundationModelsTranscript.decompose(Transcript(entries: entries))

        #expect(parts.instructions == "Be concise.")
        #expect(parts.prompt == "plan a trip")
        #expect(parts.history == [.user("hi"), .assistant("hello")])
    }

    @Test("No instructions → nil, not an empty string")
    func noInstructions() {
        let entries = FoundationModelsTranscript.entries(
            instructions: nil, history: [.user("just this")]
        )
        let parts = FoundationModelsTranscript.decompose(Transcript(entries: entries))
        #expect(parts.instructions == nil)
        #expect(parts.prompt == "just this")
        #expect(parts.history.isEmpty)
    }
}

// MARK: - User-account providers (iOS 27 front door)

@Suite("User-account providers (iOS 27)")
struct UserAccountProviderTests {

    @Test("No accounts configured → no user-account providers, regardless of OS")
    func noneConfigured() {
        #expect(AIOrchestrator.buildUserAccountProviders(from: AIConfiguration()).isEmpty)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("Configured accounts become external user-account providers")
    func builtFromConfig() {
        var config = AIConfiguration()
        config.userAccounts = [
            UserAccount(vendor: .openAI, apiKey: "sk-user"),
            UserAccount(vendor: .anthropic, apiKey: "sk-ant-user"),
        ]
        let providers = AIOrchestrator.buildUserAccountProviders(from: config)
        #expect(providers.map(\.identifier) == [.userAccount(.openAI), .userAccount(.anthropic)])
        #expect(providers.allSatisfy { $0.privacyLevel == .external })
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("User accounts trail the developer key in the prefer chains, absent in only modes")
    func chainMembership() async {
        func identifiers(_ preference: ModelPreference) async -> [ProviderIdentifier] {
            var config = AIConfiguration()
            config.preference = preference
            config.developerKey = "sk-test"
            config.userAccounts = [UserAccount(vendor: .gemini, apiKey: "AIzaUser")]
            return await AIOrchestrator(configuration: config).providerStatuses().map(\.identifier)
        }
        #expect(await identifiers(.preferOnDevice)
            == [.onDevice, .privateCloudCompute, .openAI, .userAccount(.gemini)])
        #expect(await identifiers(.developerKeyOnly) == [.openAI])
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("An account with no credential reports unavailable, never crashes")
    func unconnectedIsUnavailable() async {
        var config = AIConfiguration()
        config.enableOnDevice = false
        config.enablePrivateCloudCompute = false
        config.userAccounts = [UserAccount(vendor: .openAI, apiKey: "")]
        let statuses = await AIOrchestrator(configuration: config).providerStatuses()
        #expect(statuses.count == 1)
        #expect(statuses.first?.identifier == .userAccount(.openAI))
        #expect(statuses.first?.availability == .unavailable(reason: "Account not connected"))
    }
}

// MARK: - Custom vendor models (iOS 27)

@Suite("Custom vendor models (iOS 27)")
struct CustomLanguageModelTests {

    @Test("No custom models configured → none built, regardless of OS")
    func noneConfigured() {
        #expect(AIOrchestrator.buildCustomModelProviders(from: AIConfiguration()).isEmpty)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("A vendor LanguageModel joins the chain with its declared identity")
    func vendorModelJoinsChain() async {
        var config = AIConfiguration()
        config.enableOnDevice = false
        config.enablePrivateCloudCompute = false
        // Any LanguageModel works — our own front-door model stands in for a
        // vendor package (e.g. Firebase's Gemini).
        config.customModels = [CustomLanguageModel(
            CloudAccountLanguageModel(vendor: .gemini, apiKey: "stand-in"),
            identifier: ProviderIdentifier("firebase-gemini"),
            privacyLevel: .external
        )]
        let statuses = await AIOrchestrator(configuration: config).providerStatuses()
        #expect(statuses.map(\.identifier) == [ProviderIdentifier("firebase-gemini")])
        #expect(statuses.first?.privacyLevel == .external)
        #expect(statuses.first?.availability == .available)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test("Custom models trail the chain in prefer modes, absent in only modes")
    func chainPlacement() async {
        var config = AIConfiguration()
        config.developerKey = "sk-test"
        config.customModels = [CustomLanguageModel(
            CloudAccountLanguageModel(vendor: .anthropic, apiKey: "stand-in"),
            identifier: ProviderIdentifier("vendor-claude"),
            privacyLevel: .external
        )]
        let prefer = await AIOrchestrator(configuration: config).providerStatuses().map(\.identifier)
        #expect(prefer == [.onDevice, .privateCloudCompute, .openAI, ProviderIdentifier("vendor-claude")])

        config.preference = .developerKeyOnly
        let only = await AIOrchestrator(configuration: config).providerStatuses().map(\.identifier)
        #expect(only == [.openAI])
    }
}

// MARK: - OAuth (VoltaSDKAuth)

@Suite("OAuth PKCE")
struct PKCETests {

    @Test("S256 challenge matches the RFC 7636 test vector")
    func rfcVector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("A generated verifier is 43 URL-safe base64 characters")
    func verifierShape() {
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(verifier.allSatisfy { allowed.contains($0) })
    }
}

/// Returns a canned HTTP response for any request — mocks the token endpoint.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("OAuth token flow", .serialized)
struct OAuthTokenFlowTests {

    let config = OAuthConfiguration(
        authorizationEndpoint: URL(string: "https://idp.example/authorize")!,
        tokenEndpoint: URL(string: "https://idp.example/token")!,
        clientID: "abc123",
        redirectURI: URL(string: "voltademo://oauth")!,
        scopes: ["openid", "email"]
    )

    private func mockSession(json: String, status: Int = 200) -> URLSession {
        MockURLProtocol.body = Data(json.utf8)
        MockURLProtocol.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Authorization URL carries client_id, PKCE S256 challenge, redirect, state, scope")
    func authorizationURL() {
        let account = OAuthAccount(vendor: .gemini, configuration: config)
        // Reuse the RFC 7636 verifier so the expected challenge is known.
        let url = account.authorizationURL(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "xyz"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("client_id") == "abc123")
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == "voltademo://oauth")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(value("state") == "xyz")
        #expect(value("scope") == "openid email")
    }

    @Test("Token exchange parses access + refresh token and expiry")
    func tokenExchange() async throws {
        let session = mockSession(
            json: #"{"access_token":"tok-abc","refresh_token":"ref-xyz","expires_in":3600}"#
        )
        let account = OAuthAccount(vendor: .gemini, configuration: config, urlSession: session)
        let token = try await account.exchange(grant: ["grant_type": "authorization_code", "code": "c"])

        #expect(token.accessToken == "tok-abc")
        #expect(token.refreshToken == "ref-xyz")
        #expect(token.expiresAt != nil)
    }

    @Test("A token-endpoint error surfaces as tokenExchangeFailed")
    func tokenError() async {
        let session = mockSession(json: #"{"error":"invalid_grant"}"#, status: 400)
        let account = OAuthAccount(vendor: .gemini, configuration: config, urlSession: session)
        await #expect(throws: OAuthError.self) {
            _ = try await account.exchange(grant: ["grant_type": "authorization_code", "code": "bad"])
        }
    }
}

// MARK: - Global configuration

@Suite("Configuration", .serialized)
struct ConfigurationTests {

    @Test("configure sets the active instance")
    func configureSetsActive() async {
        AIOrchestrator.configure {
            $0.enableOnDevice = false
            $0.developerKey = nil
            $0.enablePrivateCloudCompute = false   // PCC is default-on (iOS 27)
        }
        // No providers built → none available.
        let available = await AIOrchestrator.active.availableProviders()
        #expect(available.isEmpty)
    }
}

// MARK: - Parsing

@Suite("OpenAIProvider parsing")
struct OpenAIParsingTests {

    @Test("Retry-After in seconds")
    func retryAfterSeconds() {
        #expect(OpenAIProvider.parseRetryAfter("120") == 120)
    }

    @Test("Retry-After as a future HTTP-date → positive interval")
    func retryAfterDate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss 'GMT'"
        let future = formatter.string(from: Date().addingTimeInterval(90))

        let parsed = try #require(OpenAIProvider.parseRetryAfter(future))
        #expect(parsed > 80 && parsed <= 91)
    }

    @Test("Retry-After missing or unreadable → nil")
    func retryAfterInvalid() {
        #expect(OpenAIProvider.parseRetryAfter(nil) == nil)
        #expect(OpenAIProvider.parseRetryAfter("nope") == nil)
    }
}

// MARK: - Streaming (D16)

/// A provider that implements only the required surface — exercises the
/// protocol's DEFAULT streaming (the whole answer as one fragment).
private struct BareProvider: ModelProvider {
    let identifier = ProviderIdentifier("bare")
    let privacyLevel = PrivacyLevel.onDevice
    func availability() async -> ProviderAvailability { .available }
    func respond(
        to prompt: String, instructions: String?, history: [ChatTurn]
    ) async throws -> String { "whole answer" }
}

@Suite("Streaming (D16)")
struct StreamingTests {

    private func collect(
        _ stream: AsyncThrowingStream<AIStreamEvent, Error>
    ) async throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("Default capability: the whole answer arrives as one fragment")
    func defaultSingleFragment() async throws {
        let kit = AIOrchestrator(providers: [BareProvider()])
        let events = try await collect(await kit.streamDetailed(to: "hi"))
        #expect(events == [
            .began(provider: ProviderIdentifier("bare"), privacyLevel: .onDevice),
            .text("whole answer")
        ])
    }

    @Test("Fragments arrive in order, after one began event")
    func fragmentsInOrder() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, streamFragments: ["a", "b", "c"])
        ])
        let events = try await collect(await kit.streamDetailed(to: "hi"))
        #expect(events == [
            .began(provider: .onDevice, privacyLevel: .onDevice),
            .text("a"), .text("b"), .text("c")
        ])
    }

    @Test("streamResponse convenience yields text fragments only")
    func textOnlyConvenience() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, streamFragments: ["hel", "lo"])
        ])
        var fragments: [String] = []
        for try await fragment in await kit.streamResponse(to: "hi") {
            fragments.append(fragment)
        }
        #expect(fragments == ["hel", "lo"])
    }

    @Test("Falls back when a provider fails before its first fragment")
    func fallsBackBeforeFirstFragment() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         streamFragments: [],
                         streamFailure: .rateLimited(retryAfter: nil)),
            MockProvider(identifier: .openAI,
                         privacyLevel: .external,
                         streamFragments: ["cloud"])
        ])
        let events = try await collect(await kit.streamDetailed(to: "hi"))
        #expect(events == [
            .began(provider: .openAI, privacyLevel: .external),
            .text("cloud")
        ])
    }

    @Test("A mid-stream failure surfaces instead of falling back (D16 rule)")
    func midStreamFailureSurfaces() async throws {
        let secondReached = Mutex(false)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         streamFragments: ["partial "],
                         streamFailure: .network(code: -1)),
            MockProvider(identifier: .openAI,
                         streamFragments: ["never"],
                         onRespond: { _, _, _ in secondReached.withLock { $0 = true } })
        ])

        var received: [AIStreamEvent] = []
        var thrown: ProviderError?
        do {
            for try await event in await kit.streamDetailed(to: "hi") {
                received.append(event)
            }
        } catch let error as ProviderError {
            thrown = error
        }

        // The fragment already shown is kept, the failure surfaces, and the
        // chain does NOT silently re-answer with the next provider.
        #expect(received == [
            .began(provider: .onDevice, privacyLevel: .onDevice),
            .text("partial ")
        ])
        #expect(thrown == .network(code: -1))
        #expect(secondReached.withLock { $0 } == false)
    }

    @Test("A terminal pre-fragment error stops the chain")
    func terminalErrorStopsChain() async throws {
        let secondReached = Mutex(false)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         streamFragments: [],
                         streamFailure: .unauthorized),
            MockProvider(identifier: .openAI,
                         streamFragments: ["never"],
                         onRespond: { _, _, _ in secondReached.withLock { $0 = true } })
        ])

        var thrown: ProviderError?
        do {
            for try await _ in await kit.streamDetailed(to: "hi") {}
        } catch let error as ProviderError {
            thrown = error
        }
        #expect(thrown == .unauthorized)
        #expect(secondReached.withLock { $0 } == false)
    }

    @Test("A stream that ends without fragments maps to emptyResponse")
    func emptyStreamIsEmptyResponse() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, streamFragments: [])
        ])
        var thrown: ProviderError?
        do {
            for try await _ in await kit.streamDetailed(to: "hi") {}
        } catch let error as ProviderError {
            thrown = error
        }
        #expect(thrown == .emptyResponse)
    }

    @Test("denyDowngrade excludes lower-privacy providers when streaming")
    func denyDowngradeApplies() async throws {
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice,
                             availability: .unavailable(reason: "off"),
                             streamFragments: ["never"]),
                MockProvider(identifier: .openAI,
                             privacyLevel: .external,
                             streamFragments: ["cloud"])
            ],
            privacyDisclosure: .denyDowngrade
        )
        var thrown: ProviderError?
        do {
            for try await _ in await kit.streamDetailed(to: "hi") {}
        } catch let error as ProviderError {
            thrown = error
        }
        #expect(thrown == .privacyRestricted)
    }
}

// MARK: - SSE parser (D16)

@Suite("SSE parser")
struct SSEParserTests {

    @Test("Parses data events and the [DONE] sentinel (OpenAI style)")
    func openAIStyle() {
        var parser = SSEParser()
        #expect(parser.consume("data: {\"x\":1}") == nil)
        #expect(parser.consume("") == ServerSentEvent(event: nil, data: "{\"x\":1}"))
        #expect(parser.consume("data: [DONE]") == nil)
        #expect(parser.consume("") == ServerSentEvent(event: nil, data: "[DONE]"))
    }

    @Test("Carries event names (Anthropic style)")
    func eventNames() {
        var parser = SSEParser()
        #expect(parser.consume("event: content_block_delta") == nil)
        #expect(parser.consume("data: {\"t\":1}") == nil)
        #expect(parser.consume("") == ServerSentEvent(
            event: "content_block_delta", data: "{\"t\":1}"
        ))
    }

    @Test("Joins multi-line data, ignores comments and blank dispatches")
    func multiLineAndComments() {
        var parser = SSEParser()
        #expect(parser.consume(": keep-alive") == nil)
        #expect(parser.consume("data: a") == nil)
        #expect(parser.consume("data:b") == nil)
        #expect(parser.consume("") == ServerSentEvent(event: nil, data: "a\nb"))
        #expect(parser.consume("") == nil)
    }
}

// MARK: - Dynamic Profiles bridge (iOS 27, D1)

@Suite("Dynamic Profiles bridge (iOS 27)")
struct PreferredBridgeTests {

    @Test("preferred() returns the first available provider's native model")
    func returnsFirstAvailableModel() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let account = CloudAccountLanguageModel(
            vendor: .gemini, apiKey: "AIza-test", model: "gemini-test"
        )
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, availability: .unavailable(reason: "off")),
            LanguageModelProvider(
                identifier: .userAccount(.gemini),
                privacyLevel: .external,
                model: account,
                connected: true
            )
        ])
        let model = try await kit.preferred()
        let cloud = try #require(model as? CloudAccountLanguageModel)
        #expect(cloud.vendor == .gemini)
        #expect(cloud.modelName == "gemini-test")
    }

    @Test("Developer-key providers bridge via CloudAccountLanguageModel")
    func developerKeyBridges() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let kit = AIOrchestrator(providers: [
            OpenAIProvider(apiKey: "sk-test", model: "gpt-test")
        ])
        let model = try await kit.preferred()
        let cloud = try #require(model as? CloudAccountLanguageModel)
        #expect(cloud.vendor == .openAI)
        #expect(cloud.modelName == "gpt-test")
    }

    @Test("Providers that cannot bridge are skipped, not fatal")
    func skipsNonConvertible() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let kit = AIOrchestrator(providers: [
            // Available, would win respond() — but not LanguageModelConvertible.
            MockProvider(identifier: ProviderIdentifier("custom"), outcome: .success("mock")),
            AnthropicProvider(apiKey: "sk-ant-test")
        ])
        let model = try await kit.preferred()
        let cloud = try #require(model as? CloudAccountLanguageModel)
        #expect(cloud.vendor == .anthropic)
    }

    @Test("denyDowngrade excludes lower-privacy models from the bridge")
    func denyDowngradeExcludes() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice, availability: .unavailable(reason: "off")),
                GeminiProvider(apiKey: "AIza-test")
            ],
            privacyDisclosure: .denyDowngrade
        )
        var thrown: ProviderError?
        do { _ = try await kit.preferred() } catch let error as ProviderError { thrown = error }
        #expect(thrown == .noProviderAvailable)
    }

    @Test("No convertible provider at all throws noProviderAvailable")
    func emptyChainThrows() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: ProviderIdentifier("custom"), outcome: .success("mock"))
        ])
        var thrown: ProviderError?
        do { _ = try await kit.preferred() } catch let error as ProviderError { thrown = error }
        #expect(thrown == .noProviderAvailable)
    }
}

// MARK: - Warm-session reuse (D17)

@Suite("Warm-session reuse (D17)")
struct SessionCacheTests {

    @Test("Hit only when the conversation continues exactly")
    func hitOnExactContinuation() {
        let cache = SessionCache()
        let session = LanguageModelSession()
        let conversation: [ChatTurn] = [.user("q"), .assistant("a")]

        cache.checkIn(session, instructions: "sys", history: conversation)
        #expect(cache.checkOut(instructions: "sys", history: conversation) === session)
    }

    @Test("Check-out is exclusive: a second caller builds fresh")
    func checkOutIsExclusive() {
        let cache = SessionCache()
        let session = LanguageModelSession()
        cache.checkIn(session, instructions: nil, history: [])

        #expect(cache.checkOut(instructions: nil, history: []) === session)
        #expect(cache.checkOut(instructions: nil, history: []) == nil)
    }

    @Test("A diverging history is a miss AND discards the stale entry")
    func divergenceInvalidates() {
        let cache = SessionCache()
        let session = LanguageModelSession()
        cache.checkIn(session, instructions: nil, history: [.user("q"), .assistant("a")])

        // The app trimmed its history → not a continuation → miss…
        #expect(cache.checkOut(instructions: nil, history: [.user("q")]) == nil)
        // …and the stale session must be gone, not resurrected later.
        #expect(cache.checkOut(instructions: nil, history: [.user("q"), .assistant("a")]) == nil)
    }

    @Test("Different instructions are a different conversation")
    func instructionsAreCompared() {
        let cache = SessionCache()
        let session = LanguageModelSession()
        cache.checkIn(session, instructions: "be brief", history: [])

        #expect(cache.checkOut(instructions: "be verbose", history: []) == nil)
    }
}
