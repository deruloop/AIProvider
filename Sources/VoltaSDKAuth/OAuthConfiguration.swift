//
//  OAuthConfiguration.swift
//  VoltaSDKAuth
//
//  Everything the OAuth flow needs, supplied once by the developer from their
//  app's registration with the provider. VoltaSDK automates the flow; it can't
//  invent these — the provider issues the client ID and only honours redirect
//  URIs it has on file for your app.
//

import Foundation

public struct OAuthConfiguration: Sendable, Equatable {
    /// The provider's authorization endpoint (where the user signs in).
    public var authorizationEndpoint: URL
    /// The provider's token endpoint (code → token, and refresh).
    public var tokenEndpoint: URL
    /// The client ID your app was issued when you registered it with the
    /// provider. Public by design for native PKCE clients — no secret needed.
    public var clientID: String
    /// A redirect URI your app owns and registered with the provider — a custom
    /// scheme (e.g. `myapp://oauth-callback`). The sign-in window returns here.
    public var redirectURI: URL
    /// Scopes to request (provider-specific).
    public var scopes: [String]

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        redirectURI: URL,
        scopes: [String] = []
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// The custom scheme `ASWebAuthenticationSession` listens for.
    var callbackScheme: String? { redirectURI.scheme }
}

/// Failures surfaced by the OAuth flow.
public enum OAuthError: Error, Sendable, Equatable {
    /// No stored token and no way to obtain one without interactive sign-in.
    case notSignedIn
    /// The user cancelled or dismissed the sign-in window.
    case cancelled
    /// The sign-in window couldn't be started (no presentation anchor).
    case cannotPresent
    /// The redirect came back without an authorization code.
    case missingAuthorizationCode
    /// The `state` returned didn't match — possible interception.
    case stateMismatch
    /// The token endpoint returned an error or an unparseable body.
    case tokenExchangeFailed(String)
}
