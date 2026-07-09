//
//  OAuthAccount.swift
//  VoltaSDKAuth
//
//  The managed OAuth flow. Given the developer's `OAuthConfiguration` (client
//  ID + endpoints + redirect they registered with the provider), this runs the
//  whole thing: presents the sign-in window, does PKCE, exchanges the code for
//  a token, stores it in the Keychain, and refreshes it silently when it
//  expires. The developer's remaining job is just: register the app once,
//  drop in the client ID, call `signIn()` from the UI, and hand the account to
//  `UserAccount(oauth:)`.
//
//  Note: this compiles against the iOS/macOS 27 SDK; the live flow can only be
//  exercised by a signed app whose client ID is registered with the provider.
//

import Foundation
import AuthenticationServices
import VoltaSDK

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A stored token bundle. Internal so the token flow is unit-testable.
struct OAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// What the provider says it actually granted (`scope` in the token
    /// response), when it says anything. May be less than what was requested —
    /// e.g. Google's granular consent.
    var grantedScopes: [String]?

    /// Usable for at least another minute (or no expiry info at all).
    var isFresh: Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > 60
    }
}

/// The provider's token-endpoint response (OAuth 2.0 §5.1).
private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let scope: String?
}

public final class OAuthAccount: @unchecked Sendable {
    public let vendor: CloudVendor
    private let config: OAuthConfiguration
    private let keychain: KeychainTokenStore
    private let accountKey: String

    private let lock = NSLock()
    private var cached: OAuthToken?
    /// Injectable for tests (mock the token endpoint).
    private let urlSession: URLSession

    // Retained across the interactive flow; touched only on the main actor.
    private var anchor: AnchorProvider?
    private var liveSession: ASWebAuthenticationSession?

    public init(
        vendor: CloudVendor,
        configuration: OAuthConfiguration,
        urlSession: URLSession = .shared
    ) {
        self.vendor = vendor
        self.config = configuration
        self.urlSession = urlSession
        self.keychain = KeychainTokenStore(service: "com.voltasdk.oauth")
        self.accountKey = "\(vendor.rawValue)#\(configuration.clientID)"
        if let data = keychain.load(account: accountKey),
           let token = try? JSONDecoder().decode(OAuthToken.self, from: data) {
            self.cached = token
        }
    }

    /// Whether a token is on hand (it may still need a silent refresh).
    public var isSignedIn: Bool {
        lock.withLock { cached != nil }
    }

    /// The scopes the provider says the current token carries (`scope` from
    /// the token response), when it reported them. Useful for diagnosing
    /// under-granting (granular consent, silently stripped scopes).
    public var grantedScopes: [String]? {
        lock.withLock { cached?.grantedScopes }
    }

    /// Forget the account (local only).
    public func signOut() {
        lock.withLock { cached = nil }
        keychain.delete(account: accountKey)
    }

    /// Token provider for `UserAccount`/the executor: a valid access token,
    /// refreshed silently if expired. Throws `.notSignedIn` when there's
    /// nothing to work with (the app should then run `signIn()`).
    public func token() async throws -> String {
        if let token = lock.withLock({ cached }), token.isFresh {
            return token.accessToken
        }
        guard let refresh = lock.withLock({ cached?.refreshToken }) else {
            throw OAuthError.notSignedIn
        }
        let refreshed = try await exchange(grant: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": config.clientID,
        ])
        store(refreshed)
        return refreshed.accessToken
    }

    /// Interactive sign-in — presents the provider's login, runs PKCE,
    /// exchanges the code, and stores the token. Call from your UI (e.g. the
    /// model picker's deferred hook). Main-actor because it presents a window.
    @MainActor
    public func signIn() async throws {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        let callbackURL = try await present(
            authorizationURL: authorizationURL(verifier: verifier, state: state)
        )

        guard let returnedState = queryValue("state", in: callbackURL),
              returnedState == state else {
            throw OAuthError.stateMismatch
        }
        guard let code = queryValue("code", in: callbackURL) else {
            throw OAuthError.missingAuthorizationCode
        }
        let token = try await exchange(grant: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI.absoluteString,
            "client_id": config.clientID,
            "code_verifier": verifier,
        ])

        // Fail LOUDLY at sign-in when the provider under-granted (granular
        // consent, unregistered scope, …) instead of letting API calls fail
        // later with "insufficient scopes". Only full-URL scopes are checked:
        // shorthands like "openid"/"email" come back normalized under other
        // names (e.g. …/auth/userinfo.email) and would false-positive.
        if let granted = token.grantedScopes {
            let missing = config.scopes.filter { $0.contains("://") && !granted.contains($0) }
            guard missing.isEmpty else {
                throw OAuthError.scopesNotGranted(missing: missing, granted: granted)
            }
        }
        store(token)
    }

    // MARK: Internals

    /// Builds the authorization URL (PKCE S256 + state). Internal for testing.
    func authorizationURL(verifier: String, state: String) -> URL {
        var components = URLComponents(
            url: config.authorizationEndpoint, resolvingAgainstBaseURL: false
        )!
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ])
        if !config.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }
        for (name, value) in config.additionalAuthorizationParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    @MainActor
    private func present(authorizationURL: URL) async throws -> URL {
        // An empty/invalid scheme would precondition-trap inside
        // ASWebAuthenticationSession — fail with a catchable error instead.
        guard let scheme = config.callbackScheme, !scheme.isEmpty else {
            throw OAuthError.cannotPresent
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The session's completion handler and a failed `start()` are not
            // mutually exclusive — a cancelled/failed session can still invoke
            // its completion. Resuming a checked continuation twice is a fatal
            // trap (SWIFT TASK CONTINUATION MISUSE → EXC_BREAKPOINT, on
            // whatever thread resumes second), so resumption is one-shot.
            let resumeOnce = OneShotResume(continuation)
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callback: .customScheme(scheme),
                completionHandler: Self.sessionCompletion(resumeOnce)
            )
            let anchorProvider = AnchorProvider()
            session.presentationContextProvider = anchorProvider
            session.prefersEphemeralWebBrowserSession = false
            anchor = anchorProvider
            liveSession = session
            if !session.start() {
                resumeOnce.resume(.failure(OAuthError.cannotPresent))
            }
        }
    }

    /// The session completion, built OUTSIDE any actor context — deliberately.
    ///
    /// Observed live (macOS 27 beta): `ASWebAuthenticationSession` invokes its
    /// completion on a background XPC reply queue
    /// (`com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`), not
    /// the main thread. A closure formed inside the `@MainActor present(_:)`
    /// inherits main-actor isolation, and Swift 6's *dynamic* isolation check
    /// then traps at closure entry — `dispatch_assert_queue` →
    /// `_dispatch_assert_queue_fail` → `EXC_BREAKPOINT` — before a single line
    /// of the body runs. Creating the closure in this nonisolated factory
    /// makes it invocable from any queue; resuming the one-shot continuation
    /// is thread-safe from anywhere.
    private nonisolated static func sessionCompletion(
        _ resumeOnce: OneShotResume
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            if let callbackURL {
                resumeOnce.resume(.success(callbackURL))
            } else {
                resumeOnce.resume(.failure(error ?? OAuthError.cancelled))
            }
        }
    }

    /// Posts a grant to the token endpoint and parses the token. Internal so
    /// the exchange/refresh can be unit-tested with a mocked `URLSession`.
    func exchange(grant: [String: String]) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(grant)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw OAuthError.tokenExchangeFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw OAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(body)")
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OAuthError.tokenExchangeFailed("Unparseable token response")
        }
        return OAuthToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: decoded.expires_in.map { Date(timeIntervalSinceNow: $0) },
            grantedScopes: decoded.scope.map { $0.split(separator: " ").map(String.init) }
        )
    }

    private func store(_ token: OAuthToken) {
        lock.withLock { cached = token }
        if let data = try? JSONEncoder().encode(token) {
            keychain.save(data, account: accountKey)
        }
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private func formEncode(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

// MARK: - One-shot continuation

/// Wraps a checked continuation so that only the FIRST resume wins — any later
/// attempt is silently dropped instead of trapping the process.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<URL, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

// MARK: - Presentation anchor

private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Bridge to the core UserAccount

public extension UserAccount {
    /// Build a chain provider whose credential is managed by OAuth: the token
    /// comes from `account`, refreshed silently. Run `account.signIn()` from
    /// your UI first (e.g. the model picker's deferred hook).
    init(oauth account: OAuthAccount) {
        self.init(
            vendor: account.vendor,
            isConnected: account.isSignedIn,
            token: { try await account.token() }
        )
    }
}
