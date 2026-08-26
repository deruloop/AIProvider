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
//     connect flow for a user-account vendor).
//
//  Why the connect flow is key-only (verified live + against vendor policy,
//  2026): none of the big three permits third-party apps to run
//  subscription-backed generation on a user's personal sign-in. Google
//  deprecated the per-user-quota scope and bans proxying its CLI client;
//  Anthropic's terms restrict Claude Free/Pro/Max OAuth tokens to its own
//  products; OpenAI's "Sign in with ChatGPT" shares identity, not plan-backed
//  inference. The sanctioned "user account" routes are the user's own API
//  key (this sheet) and the vendor's official package, which plugs into the
//  chain via `AIConfiguration.customModels`.
//
//  Adaptive layout:
//   - macOS: HSplitView (developer | user)
//   - iOS:   TabView (Developer / User)
//

import SwiftUI
import VoltaSDK
import VoltaSDKUI

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
    /// Keys the user pasted in the connect flow.
    @State private var connectedTokens: [CloudVendor: String] = [:]

    // Connect flow (a user-account row → the user's own API key). Setting the
    // vendor presents the sheet via `.sheet(item:)`, so the vendor is always
    // available when the sheet renders.
    @State private var pendingConnectVendor: CloudVendor?
    @State private var connectKey = ""

    // Developer-key paywall flow.
    @State private var pendingProvider: ProviderIdentifier?
    @State private var showsPaywall = false

    @State private var orchestrator = AIOrchestrator(configuration: AIConfiguration())
    @State private var downgradeLog = DowngradeLog()

    // MARK: Vendor package (customModels) — supplied by the HOST APP

    /// Display name for the vendor-package section (nil = section hidden).
    private let vendorPackageName: String?
    /// Type-erased `@Sendable (String) -> [CustomLanguageModel]` — the app
    /// builds the vendor's `LanguageModel`(s) from the developer-entered key.
    /// Stored erased because the closure's type mentions an iOS-27-only type
    /// and stored properties can't be availability-gated.
    private let _vendorPackageFactory: Any?
    @State private var vendorPackageEnabled = false
    @State private var vendorPackageKey = ""

    public init() {
        self.vendorPackageName = nil
        self._vendorPackageFactory = nil
    }

    /// Host apps built for OS 27 can hand in an official vendor package
    /// (e.g. Anthropic's ClaudeForFoundationModels): the demo shows a section
    /// for it, and the models returned by `makeVendorModels` join the chain
    /// via `AIConfiguration.customModels`.
    @available(iOS 27.0, macOS 27.0, *)
    public init(
        vendorPackageName: String,
        makeVendorModels: @escaping @Sendable (String) -> [CustomLanguageModel]
    ) {
        self.vendorPackageName = vendorPackageName
        self._vendorPackageFactory = makeVendorModels
    }

    /// The developer knobs that require an explicit "Apply".
    private struct AppliedSettings: Equatable {
        var enableOnDevice = true
        var enablePrivateCloudCompute = true
        var apiKey = ""
        var model = ""
        var offeredVendors: Set<CloudVendor> = []
        var vendorPackageEnabled = false
        var vendorPackageKey = ""
        var notifyDowngrades = true
    }

    private var liveSettings: AppliedSettings {
        AppliedSettings(
            enableOnDevice: enableOnDevice,
            enablePrivateCloudCompute: enablePrivateCloudCompute,
            apiKey: apiKey,
            model: model,
            offeredVendors: offeredVendors,
            vendorPackageEnabled: vendorPackageEnabled,
            vendorPackageKey: vendorPackageKey,
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
                            }
                        }
                    ))
                    if connectedTokens[vendor] != nil {
                        Label("Connected by the user", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text("Developer's choice: which vendors to expose. Each offered vendor appears in the picker; the USER connects their own account by tapping the row and entering their key (vendors don't permit subscription sign-in for third-party apps — the official vendor packages plug in via customModels instead). To route a call to it, turn the other providers off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let vendorPackageName {
                Section("Official vendor package (customModels)") {
                    Toggle("Enable \(vendorPackageName)", isOn: $vendorPackageEnabled)
                    if vendorPackageEnabled {
                        SecureField("Vendor API key (developer's — dev billing)", text: $vendorPackageKey)
                            .textContentType(.password)
                    }
                    Text("The vendor's own Swift package, conforming to Apple's LanguageModel protocol, joins the chain via AIConfiguration.customModels. Developer-provisioned: usage bills the app's vendor account (App Attest or a proxy in production; a key here for development).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            // The Dynamic Profiles bridge (D1): a native profile fed by the
            // chain's resolved model. iOS 27 machinery — absent on 26.
            if #available(iOS 27.0, macOS 27.0, *) {
                ProfileBridgeSection(orchestrator: orchestrator)
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
                    // it; otherwise run the connect flow (their API key) and
                    // commit when it succeeds.
                    if provider.rawValue.hasPrefix("user-") {
                        guard let vendor = CloudVendor.allCases.first(where: {
                            provider == .userAccount($0)
                        }) else {
                            return .deny(message: "Unknown account vendor")
                        }
                        if connectedTokens[vendor] != nil { return .activate }
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
    /// user-account row: the user provides their own API key, billed to them.
    /// There is deliberately NO "Sign in with <Vendor>" here — none of the
    /// big three permits subscription-backed generation on a personal sign-in
    /// for third-party apps (see the header note); the official vendor
    /// packages are the sanctioned sign-in route and join the chain via
    /// `AIConfiguration.customModels`.
    private func connectSheet(_ vendor: CloudVendor) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Connect your \(vendor.rawValue) account")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Paste your own \(vendor.rawValue) API key — usage is billed to you, not the app. The key stays on this device.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SecureField("Your \(vendor.rawValue) API key", text: $connectKey)
                .textFieldStyle(.roundedBorder)
            Button("Connect") {
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

    // MARK: Configuration

    /// Commit the developer form: snapshot it and rebuild the orchestrator.
    private func apply() {
        applied = liveSettings
        rebuild()
    }

    /// Build the orchestrator from the last *applied* developer settings plus
    /// runtime state (connected keys, the user's committed selection).
    private func rebuild() {
        let log = downgradeLog
        var config = AIConfiguration()
        config.enableOnDevice = applied.enableOnDevice
        config.enablePrivateCloudCompute = applied.enablePrivateCloudCompute
        config.developerKey = applied.apiKey.isEmpty ? nil : applied.apiKey
        config.developerKeyModel = applied.model.isEmpty ? nil : applied.model
        // Each offered vendor becomes a selectable row; its token provider
        // carries whatever key the user connected (empty until they do).
        config.userAccounts = applied.offeredVendors
            .sorted { $0.rawValue < $1.rawValue }
            .map { vendor in
                let token = connectedTokens[vendor] ?? ""
                return UserAccount(vendor: vendor, isConnected: true, token: { token })
            }
        // Official vendor package (host-app-supplied): the developer enabled it
        // and provided a key → the app's factory builds the vendor's
        // LanguageModel(s), which join the chain via customModels.
        if #available(iOS 27.0, macOS 27.0, *),
           applied.vendorPackageEnabled,
           !applied.vendorPackageKey.isEmpty,
           let factory = _vendorPackageFactory as? (@Sendable (String) -> [CustomLanguageModel]) {
            config.customModels = factory(applied.vendorPackageKey)
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
