//
//  DemoRootView.swift
//  VoltaSDKDemoUI
//
//  Test UI shared between the macOS demo (Examples/macOSDemo) and the iOS demo
//  (Examples/iOSDemo). It mirrors the two roles in a real integration:
//
//   - DEVELOPER side: the configuration form (which providers exist, the
//     developer key, which user-account vendors to offer, privacy policy).
//     Nothing takes effect until "Apply configuration" is pressed.
//   - USER side: the chat on top and the ModelSelector below it — the user
//     picks a model; free providers activate immediately, gated ones defer to
//     the app's own flow (a paywall for the developer-key cloud model; a
//     connect/OAuth flow for a user-account vendor).
//
//  Adaptive layout:
//   - macOS: HSplitView (developer | user)
//   - iOS:   TabView (Developer / User)
//

import SwiftUI
import VoltaSDK
import VoltaSDKUI
import VoltaSDKAuth

/// Privacy-downgrade events collected by the `.notify` policy, surfaced
/// in the test UI.
@MainActor @Observable
final class DowngradeLog {
    var events: [String] = []
}

public struct DemoRootView: View {
    // MARK: Developer configuration (LIVE form state — applied only on "Apply")
    @State private var enableOnDevice = true
    @State private var enablePrivateCloudCompute = true
    @State private var apiKey = ""
    @State private var model = ""
    @State private var offeredVendors: Set<CloudVendor> = []
    /// The app's registered Google OAuth client ID (from Google Cloud Console)
    /// — the one step no SDK can do for you. With it, the Gemini row's
    /// "Sign in" runs REAL managed OAuth via VoltaSDKAuth. Persisted locally
    /// (UserDefaults) so it's pasted once, never committed anywhere.
    @AppStorage("volta.demo.googleOAuthClientID") private var googleOAuthClientID = ""
    @State private var notifyDowngrades = true

    /// Snapshot of the last *applied* developer settings. The orchestrator is
    /// built from this — so form edits do nothing until "Apply configuration",
    /// and user actions never pick up un-applied changes.
    @State private var applied = AppliedSettings()

    // MARK: User runtime state
    /// Simulated entitlement for the developer-key cloud model (StoreKit stand-in).
    @State private var userHasSubscription = true
    /// What the end user committed in the ModelSelector.
    @State private var userSelection: ProviderIdentifier?
    /// Keys the user pasted in the connect flow (the manual path).
    @State private var connectedTokens: [CloudVendor: String] = [:]
    /// Accounts connected via REAL managed OAuth (VoltaSDKAuth) — the token
    /// lives in the Keychain and refreshes silently.
    @State private var oauthAccounts: [CloudVendor: OAuthAccount] = [:]
    @State private var connectError: String?

    // Connect flow (a user-account row → sign-in / API key). Setting the
    // vendor presents the sheet via `.sheet(item:)`, so the vendor is always
    // available when the sheet renders.
    @State private var pendingConnectVendor: CloudVendor?
    @State private var connectKey = ""

    // Developer-key paywall flow.
    @State private var pendingProvider: ProviderIdentifier?
    @State private var showsPaywall = false

    @State private var orchestrator = AIOrchestrator(configuration: AIConfiguration())
    @State private var downgradeLog = DowngradeLog()

    public init() {}

    /// The developer knobs that require an explicit "Apply".
    private struct AppliedSettings: Equatable {
        var enableOnDevice = true
        var enablePrivateCloudCompute = true
        var apiKey = ""
        var model = ""
        var offeredVendors: Set<CloudVendor> = []
        var googleOAuthClientID = ""
        var notifyDowngrades = true
    }

    private var liveSettings: AppliedSettings {
        AppliedSettings(
            enableOnDevice: enableOnDevice,
            enablePrivateCloudCompute: enablePrivateCloudCompute,
            apiKey: apiKey,
            model: model,
            offeredVendors: offeredVendors,
            googleOAuthClientID: googleOAuthClientID,
            notifyDowngrades: notifyDowngrades
        )
    }

    private var hasUnappliedChanges: Bool { liveSettings != applied }

    public var body: some View {
        platformLayout
            .onAppear { apply() }
            // The user's committed choice re-leads the chain — a runtime action,
            // built from the last-applied config (not un-applied edits).
            .onChange(of: userSelection) { rebuild() }
    }

    // MARK: Per-platform layout

    @ViewBuilder
    private var platformLayout: some View {
        #if os(macOS)
        HSplitView {
            configurationForm
                .frame(minWidth: 300, maxWidth: 360)
            userPane
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        #else
        TabView {
            Tab("Developer", systemImage: "gearshape") {
                NavigationStack {
                    configurationForm
                        .navigationTitle("Developer")
                }
            }
            Tab("User", systemImage: "person.crop.circle") {
                NavigationStack {
                    userPane
                        .navigationTitle("User")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        #endif
    }

    // MARK: Developer side

    private var configurationForm: some View {
        Form {
            Section("Providers") {
                Toggle("On-device model", isOn: $enableOnDevice)
                Toggle("Private Cloud Compute", isOn: $enablePrivateCloudCompute)
                Text("Apple-hosted free tier (iOS/macOS 27). Needs the Private Cloud Compute entitlement to actually answer; without it the row stays unavailable and the chain falls back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Developer API key (OpenAI, Claude, or Gemini)", text: $apiKey)
                    .textContentType(.password)
                // The model is a CONSEQUENCE of the key: the field appears
                // once a key exists, scoped to the detected vendor.
                if !apiKey.isEmpty {
                    if let vendor = detectedVendor {
                        Label("\(vendor.rawValue) key detected", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Unknown key format — OpenAI assumed",
                              systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("\(effectiveVendor.rawValue) model — default: \(effectiveVendor.defaultModel)", text: $model)
                        .autocorrectionDisabled()
                    Link(destination: effectiveVendor.modelDocumentationURL) {
                        Label("\(effectiveVendor.rawValue) model catalog",
                              systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
            Section("Offer user accounts (iOS/macOS 27)") {
                ForEach(CloudVendor.allCases, id: \.self) { vendor in
                    Toggle("Offer \(vendor.rawValue)", isOn: Binding(
                        get: { offeredVendors.contains(vendor) },
                        set: { isOn in
                            if isOn {
                                offeredVendors.insert(vendor)
                            } else {
                                offeredVendors.remove(vendor)
                                connectedTokens[vendor] = nil
                                // Fully sign out (Keychain too) so re-offering
                                // runs a fresh sign-in — e.g. after a scope change.
                                oauthAccounts[vendor]?.signOut()
                                oauthAccounts[vendor] = nil
                            }
                        }
                    ))
                    if connectedTokens[vendor] != nil || oauthAccounts[vendor] != nil {
                        Label(
                            oauthAccounts[vendor] != nil
                                ? "Connected by the user (OAuth)"
                                : "Connected by the user",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                if offeredVendors.contains(.gemini) {
                    TextField("Google OAuth client ID (…apps.googleusercontent.com)",
                              text: $googleOAuthClientID)
                        .autocorrectionDisabled()
                    Text("Your app's registered OAuth client from Google Cloud Console — the one step no SDK can do for you. With it, the Gemini row's \"Sign in\" runs the real managed OAuth flow (VoltaSDKAuth).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Developer's choice: which vendors to expose. Each offered vendor appears in the picker; the USER connects their own account by tapping the row (sign-in or their key). To route a call to it, turn the other providers off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Notify privacy downgrades", isOn: $notifyDowngrades)
                if !downgradeLog.events.isEmpty {
                    ForEach(downgradeLog.events.indices, id: \.self) { index in
                        Text(downgradeLog.events[index])
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Simulated entitlements") {
                Toggle("User has an active subscription", isOn: $userHasSubscription)
                Text("Runtime, not configuration. On: selecting the developer-key cloud model activates directly. Off: it defers to the demo paywall sheet — the custom-flow path your app controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    withAnimation { apply() }
                } label: {
                    Label(
                        hasUnappliedChanges ? "Apply configuration" : "Configuration applied",
                        systemImage: hasUnappliedChanges
                            ? "exclamationmark.arrow.triangle.2.circlepath"
                            : "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnappliedChanges)
                #if os(macOS)
                .keyboardShortcut("r")
                #endif
                Text(hasUnappliedChanges
                     ? "You have unapplied changes — press Apply to rebuild the provider chain."
                     : "Provider configuration takes effect only when applied.")
                    .font(.caption)
                    .foregroundStyle(hasUnappliedChanges ? .orange : .secondary)
            }
            Section {
                ProviderStatusList(orchestrator: orchestrator)
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private var detectedVendor: CloudVendor? {
        apiKey.isEmpty ? nil : CloudVendor.detect(fromKey: apiKey)
    }

    /// Detection result with the documented fallback (unknown → OpenAI).
    private var effectiveVendor: CloudVendor {
        detectedVendor ?? .openAI
    }

    // MARK: User side

    private var userPane: some View {
        VStack(spacing: 12) {
            // The chat, gated on a committed selection (`selection == nil` =
            // "no model committed yet"): the production pattern the selector's
            // contract asks for.
            AIPlaygroundView(
                orchestrator: orchestrator,
                instructions: nil,
                placeholder: "Try a prompt (e.g. \"Plan a weekend in Rome\")"
            )
            .disabled(userSelection == nil)
            .opacity(userSelection == nil ? 0.5 : 1)

            if userSelection == nil {
                Label("Choose a model below to start the conversation",
                      systemImage: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // The user-side selector. The handler decides per tap: activate,
            // deny, or defer to a flow the app owns (paywall / connect).
            ModelSelector(
                orchestrator: orchestrator,
                selection: $userSelection,
                onSelection: { provider in
                    // On-device and Private Cloud Compute are free — immediate.
                    guard provider != .onDevice, provider != .privateCloudCompute else {
                        return .activate
                    }
                    // A user account: if the user has already connected it, use
                    // it; otherwise run the connect flow (sign-in / API key) and
                    // commit when it succeeds.
                    if provider.rawValue.hasPrefix("user-") {
                        guard let vendor = CloudVendor.allCases.first(where: {
                            provider == .userAccount($0)
                        }) else {
                            return .deny(message: "Unknown account vendor")
                        }
                        if connectedTokens[vendor] != nil || oauthAccounts[vendor] != nil {
                            return .activate
                        }
                        pendingConnectVendor = vendor   // presents the connect sheet
                        return .deferred
                    }
                    // Developer-key cloud model — subscription check (StoreKit
                    // stand-in). Not entitled → defer to the paywall sheet.
                    try? await Task.sleep(for: .milliseconds(400))
                    if userHasSubscription { return .activate }
                    pendingProvider = provider
                    showsPaywall = true
                    return .deferred
                }
            )
        }
        .padding()
        .sheet(isPresented: $showsPaywall) { paywallSheet }
        .sheet(item: $pendingConnectVendor) { vendor in connectSheet(vendor) }
    }

    /// Stand-in for the app's own subscription gate (StoreKit / a paywall).
    /// The selector returned `.deferred`; this view commits by setting the
    /// `userSelection` binding.
    private var paywallSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Go Premium")
                .font(.title2.bold())
            Text("The developer-key cloud model is part of the premium plan. This sheet stands in for whatever gate your app needs — a paywall, a settings page, StoreKit.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Subscribe") {
                userHasSubscription = true
                userSelection = pendingProvider
                pendingProvider = nil
                showsPaywall = false
            }
            .buttonStyle(.borderedProminent)
            Button("Not now") {
                pendingProvider = nil
                showsPaywall = false
            }
            .buttonStyle(.borderless)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
    }

    /// The user-side "connect your account" flow, reached by tapping a
    /// user-account row. How the app connects the account is its own choice —
    /// like Xcode, it can offer sign-in and/or a key. This demo wires the key
    /// path; real OAuth (e.g. Firebase for Gemini) needs the app's own
    /// infrastructure, so "Sign in" is shown but stubbed.
    private func connectSheet(_ vendor: CloudVendor) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Connect your \(vendor.rawValue) account")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("The framework only needs a token provider — your app picks how to get it. Both paths below are what a real app would offer.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // REAL managed OAuth (VoltaSDKAuth) — live for Gemini once the
            // developer supplies their registered Google client ID; the other
            // vendors show the same button, enabled when their client exists.
            let oauthReady = vendor == .gemini && !applied.googleOAuthClientID.isEmpty
            Button {
                Task { await signIn(vendor: vendor) }
            } label: {
                Label("Sign in with \(vendor.rawValue)…", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!oauthReady)
            Text(oauthReady
                 ? "Runs the real OAuth flow: sign-in window, PKCE, token exchange, Keychain."
                 : "OAuth sign-in — enable by registering your app with the provider and entering the client ID on the Developer side (Google client ID for Gemini).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let connectError {
                Text(connectError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            SecureField("Provide an API key", text: $connectKey)
                .textFieldStyle(.roundedBorder)
            Button("Connect with key") {
                let token = connectKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return }
                connectedTokens[vendor] = token
                rebuild()
                userSelection = .userAccount(vendor)     // commit the choice
                connectKey = ""
                pendingConnectVendor = nil                // dismisses the sheet
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel") {
                connectKey = ""
                pendingConnectVendor = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 380)
        #endif
    }

    // MARK: Managed OAuth (VoltaSDKAuth)

    /// Google's standard OAuth endpoints. For a native client the redirect is
    /// the REVERSED client ID as a custom scheme — no secret, pure PKCE.
    private func googleOAuthConfiguration(clientID: String) -> OAuthConfiguration? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let reversed = "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
        guard let redirect = URL(string: "\(reversed):/oauth2redirect") else { return nil }
        return OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: clientID,
            redirectURI: redirect,
            // Learned live: OAuth Gemini generation is per-ENDPOINT, not
            // per-product. generativelanguage.googleapis.com (Developer API)
            // rejects user tokens for generateContent regardless of granted
            // scopes; the endpoint that accepts them is the Code Assist front
            // end (cloudcode-pa.googleapis.com — what Google's own Gemini CLI
            // uses after "Sign in with Google"), with exactly this
            // cloud-platform scope. GeminiProvider routes OAuth tokens there
            // automatically.
            scopes: ["https://www.googleapis.com/auth/cloud-platform", "openid", "email"],
            // Google specifics: without access_type=offline no refresh token is
            // ever issued (the session would die after ~1h); prompt=consent
            // re-shows the granular consent screen so a newly added scope can
            // actually be ticked and granted.
            additionalAuthorizationParameters: [
                "access_type": "offline",
                "prompt": "consent",
            ]
        )
    }

    /// Runs the REAL managed OAuth flow for the vendor and, on success,
    /// connects the account and commits the selection.
    @MainActor
    private func signIn(vendor: CloudVendor) async {
        connectError = nil
        guard vendor == .gemini,
              let config = googleOAuthConfiguration(clientID: applied.googleOAuthClientID)
        else {
            connectError = "No registered OAuth client for \(vendor.rawValue)."
            return
        }
        let account = OAuthAccount(vendor: vendor, configuration: config)
        do {
            try await account.signIn()      // sign-in window → PKCE → token → Keychain
            print("VoltaSDKAuth signed in. Granted scopes: \(account.grantedScopes ?? ["(not reported)"])")
            oauthAccounts[vendor] = account
            rebuild()
            userSelection = .userAccount(vendor)   // commit the choice
            pendingConnectVendor = nil              // dismisses the sheet
        } catch {
            connectError = "Sign-in failed: \(error)"
            print("VoltaSDKAuth sign-in error:\n\(error)")   // full text in the Xcode console
        }
    }

    // MARK: Configuration

    /// Commit the developer form: snapshot it and rebuild the orchestrator.
    private func apply() {
        applied = liveSettings
        rebuild()
    }

    /// Build the orchestrator from the last *applied* developer settings plus
    /// runtime state (connected tokens, the user's committed selection).
    private func rebuild() {
        let log = downgradeLog
        var config = AIConfiguration()
        config.enableOnDevice = applied.enableOnDevice
        config.enablePrivateCloudCompute = applied.enablePrivateCloudCompute
        config.developerKey = applied.apiKey.isEmpty ? nil : applied.apiKey
        config.developerKeyModel = applied.model.isEmpty ? nil : applied.model
        // Each offered vendor becomes a selectable row. An OAuth-connected
        // account uses the managed token (Keychain + silent refresh);
        // otherwise the token provider carries whatever key the user pasted.
        config.userAccounts = applied.offeredVendors
            .sorted { $0.rawValue < $1.rawValue }
            .map { vendor in
                if let oauth = oauthAccounts[vendor] {
                    return UserAccount(oauth: oauth)
                }
                let token = connectedTokens[vendor] ?? ""
                return UserAccount(vendor: vendor, isConnected: true, token: { token })
            }
        config.preference = effectivePreference
        if applied.notifyDowngrades {
            config.privacyDisclosure = .notify { downgrade in
                Task { @MainActor in
                    log.events.append(
                        "Downgrade: \(downgrade.from) → \(downgrade.to) via \(downgrade.provider)"
                    )
                }
            }
        }
        orchestrator = AIOrchestrator(configuration: config)
    }

    /// The user's committed selection leads the chain; on-device order is the
    /// default until they pick. (Per-provider routing gets richer with the
    /// per-need chains in the iOS 27 work.)
    private var effectivePreference: ModelPreference {
        switch userSelection {
        case .onDevice:
            return .preferOnDevice
        case .openAI, .anthropic, .gemini:
            return .preferDeveloperKey
        default:
            return .preferOnDevice
        }
    }
}
