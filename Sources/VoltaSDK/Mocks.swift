//
//  Mocks.swift
//  VoltaSDK
//
//  Inherits the pattern of the original ChatGptManagerMock, generalized.
//  Lets you test the orchestrator and the fallback without network or a
//  real device. Public on purpose: adopters can use it in their own tests.
//

import Foundation

/// Fake provider with a configurable outcome. Covers both success and
/// failure, so the fallback chain can be tested (e.g. one provider that
/// returns .rateLimited and one that answers correctly right after).
public struct MockProvider: ModelProvider {

    public let identifier: ProviderIdentifier
    public let privacyLevel: PrivacyLevel

    private let availabilityResult: ProviderAvailability
    private let outcome: Result<String, ProviderError>
    private let onRespond: (@Sendable (_ prompt: String, _ instructions: String?, _ history: [ChatTurn]) -> Void)?

    /// Simulated token-awareness capability (D13). Default: unsupported.
    public let contextSize: Int?
    private let tokenCountValue: Int?

    /// Simulated streaming capability (D16). When set, `streamResponse`
    /// yields these fragments (then fails with `streamFailure`, if any);
    /// when nil, streaming mirrors `outcome` as a single fragment.
    private let streamFragments: [String]?
    private let streamFailure: ProviderError?

    public init(
        identifier: ProviderIdentifier,
        privacyLevel: PrivacyLevel = .onDevice,
        availability: ProviderAvailability = .available,
        outcome: Result<String, ProviderError> = .success(""),
        contextSize: Int? = nil,
        tokenCount: Int? = nil,
        streamFragments: [String]? = nil,
        streamFailure: ProviderError? = nil,
        onRespond: (@Sendable (_ prompt: String, _ instructions: String?, _ history: [ChatTurn]) -> Void)? = nil
    ) {
        self.identifier = identifier
        self.privacyLevel = privacyLevel
        self.availabilityResult = availability
        self.outcome = outcome
        self.contextSize = contextSize
        self.tokenCountValue = tokenCount
        self.streamFragments = streamFragments
        self.streamFailure = streamFailure
        self.onRespond = onRespond
    }

    public func availability() async -> ProviderAvailability {
        availabilityResult
    }

    public func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? {
        tokenCountValue
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        onRespond?(prompt, instructions, history)
        switch outcome {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        }
    }

    public func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                onRespond?(prompt, instructions, history)
                if let streamFragments {
                    for fragment in streamFragments {
                        continuation.yield(fragment)
                    }
                    continuation.finish(throwing: streamFailure)
                } else {
                    switch outcome {
                    case .success(let text):
                        continuation.yield(text)
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
