//
//  PKCE.swift
//  VoltaSDKAuth
//
//  Proof Key for Code Exchange (RFC 7636) — the mechanism that lets a native
//  app do the OAuth authorization-code flow with no client secret. The SDK
//  generates a random verifier, sends its SHA-256 challenge on the way in, and
//  proves possession of the verifier at token exchange.
//

import Foundation
import CryptoKit

enum PKCE {
    /// A high-entropy code verifier: 43 base64url chars from 32 random bytes.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Fallback: still random, just not via the security RNG.
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    /// S256 challenge = base64url( SHA256( verifier ) ).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// Base64 URL-safe with padding stripped (RFC 7636 §3).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
