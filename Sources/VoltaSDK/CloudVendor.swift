//
//  CloudVendor.swift
//  VoltaSDK
//
//  The developer key is vendor-agnostic (D15): the same configuration slot
//  accepts an OpenAI, Anthropic (Claude), or Google (Gemini) key. The vendor
//  is auto-detected from the key's format — every vendor uses a distinct
//  prefix — and can be overridden explicitly when detection isn't possible.
//
//  The model name travels WITH the key: a model string only makes sense for
//  the vendor that issued the key (a "claude-*" model with an OpenAI key is
//  a configuration error). When no model is provided, each vendor has a
//  sensible default.
//

import Foundation

/// The cloud vendor a developer key belongs to.
public enum CloudVendor: String, Sendable, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Google Gemini"

    public var id: String { rawValue }

    /// Best-effort detection from the key format:
    /// `sk-ant-…` → Anthropic, `AIza…` → Google, `sk-…` → OpenAI.
    /// Order matters: the Anthropic prefix is a superset of OpenAI's.
    public static func detect(fromKey key: String) -> CloudVendor? {
        if key.hasPrefix("sk-ant-") { return .anthropic }
        if key.hasPrefix("AIza") { return .gemini }
        if key.hasPrefix("sk-") { return .openAI }
        return nil
    }

    /// Model used when the developer doesn't specify one.
    public var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o-mini"
        case .anthropic: return "claude-opus-4-8"
        case .gemini:    return "gemini-2.5-flash"
        }
    }

    /// Where the developer can find the current model names.
    /// Surfaced by the demo so the model field is never "just a string".
    public var modelDocumentationURL: URL {
        switch self {
        case .openAI:
            return URL(string: "https://platform.openai.com/docs/models")!
        case .anthropic:
            return URL(string: "https://platform.claude.com/docs/en/about-claude/models/overview")!
        case .gemini:
            return URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        }
    }

    public var providerIdentifier: ProviderIdentifier {
        switch self {
        case .openAI:    return .openAI
        case .anthropic: return .anthropic
        case .gemini:    return .gemini
        }
    }
}

/// `Retry-After` can be seconds ("120") or an HTTP-date. Shared by all
/// cloud providers.
enum RetryAfterParser {
    static func parse(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
