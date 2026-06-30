//
//  DemoRootView.swift
//  VoltaSDKDemoUI
//
//  Test UI shared between the macOS demo (`swift run VoltaSDKDemo`)
//  and the iOS demo app (Examples/iOSDemo). It deliberately mirrors the
//  two roles in a real integration:
//
//   - DEVELOPER side: the configuration form (which providers exist, keys,
//     fallback preference, privacy policy) + "Apply configuration".
//   - USER side: the chat on top and the ModelSelector below it — the user
//     picks the model, the developer's activation gate runs (here, a
//     simulated subscription check for the cloud model), and the chat shows
//     the result of configuration × user preference.
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
    // Developer configuration (recreates the orchestrator on "Apply").
    @State private var enableOnDevice = true
    @State private var enablePrivateCloudCompute = true
    @State private var apiKey = ""
    @State private var model = ""
    @State private var preference: ModelPreference = .preferOnDevice
    @State private var notifyDowngrades = true

    // Simulated entitlement: in a real app this would be your paywall /
    // StoreKit check. The cloud-model row is gated on it.
    @State private var userHasSubscription = true

    // User-account providers (iOS 27): the user's own OpenAI/Claude/Gemini.
    @State private var userAccounts: [UserAccount] = []
    @State private var newAccountVendor: CloudVendor = .openAI
    @State private var newAccountKey = ""

    // User-side state: what the end user picked in the ModelSelector.
    @State private var userSelection: ProviderIdentifier?

    // Custom-flow demo state: the provider waiting on the paywall sheet.
    @State private var pendingProvider: ProviderIdentifier?
    @State private var showsPaywall = false

    @State private var orchestrator = AIOrchestrator(configuration: AIConfiguration())
    @State private var downgradeLog = DowngradeLog()

    public init() {}

    public var body: some View {
        platformLayout
            .onAppear { applyConfiguration() }
            .onChange(of: userSelection) {
                // The user's choice re-leads the fallback chain.
                applyConfiguration()
            }
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
                SecureField("API key (OpenAI, Claude, or Gemini)", text: $apiKey)
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
                Picker("Default preference", selection: $preference) {
                    Text("On-device first").tag(ModelPreference.preferOnDevice)
                    Text("Developer key first").tag(ModelPreference.preferDeveloperKey)
                    Text("On-device only").tag(ModelPreference.onDeviceOnly)
                    Text("Developer key only").tag(ModelPreference.developerKeyOnly)
                }
            }
            Section("Your accounts (iOS/macOS 27)") {
                Picker("Vendor", selection: $newAccountVendor) {
                    ForEach(CloudVendor.allCases, id: \.self) { vendor in
                        Text(vendor.rawValue).tag(vendor)
                    }
                }
                SecureField("Your \(newAccountVendor.rawValue) key", text: $newAccountKey)
                    .textContentType(.password)
                Button("Add account") {
                    let key = newAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    userAccounts.append(UserAccount(vendor: newAccountVendor, apiKey: key))
                    newAccountKey = ""
                    applyConfiguration()
                }
                ForEach(userAccounts.indices, id: \.self) { index in
                    HStack {
                        Label(userAccounts[index].vendor.rawValue, systemImage: "person.crop.circle")
                        Spacer()
                        Button(role: .destructive) {
                            userAccounts.remove(at: index)
                            applyConfiguration()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("The user's own account, billed to them. It appears in the picker as a gated option (the user connects it); to route a call to it, turn the other providers off.")
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
                Text("On: selecting the cloud model on the User side activates directly. Off: the selection defers to a demo paywall sheet — the custom-flow path your app controls (on iOS 27, e.g. a page that runs a provider's OAuth).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Apply configuration") { applyConfiguration() }
                #if os(macOS)
                    .keyboardShortcut("r")
                #endif
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
            // The chat: shows the result of configuration × user preference.
            // Gated on a committed selection (`selection == nil` = "no model
            // committed yet"): without this, a fallback preference would let
            // a gated provider answer before ever passing the activation
            // gate. This is the production pattern the selector's contract
            // asks for.
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

            // The user-side selector. The handler decides per tap:
            // activate, deny, or defer to a custom flow the app owns.
            ModelSelector(
                orchestrator: orchestrator,
                selection: $userSelection,
                onSelection: { provider in
                    // On-device and Private Cloud Compute are free; the user's
                    // own connected account is theirs to use — all activate
                    // immediately, with no app-side paywall.
                    guard provider != .onDevice,
                          provider != .privateCloudCompute,
                          !provider.rawValue.hasPrefix("user-") else {
                        return .activate
                    }
                    // Developer-key cloud model — entitlement check (in a real
                    // app: StoreKit).
                    try? await Task.sleep(for: .milliseconds(400))
                    if userHasSubscription { return .activate }
                    // Not entitled: the APP takes over with its own view —
                    // here a paywall sheet; on iOS 27 it could be a page
                    // that runs the provider's OAuth flow. The sheet commits
                    // the choice later by setting `userSelection`.
                    pendingProvider = provider
                    showsPaywall = true
                    return .deferred
                }
            )
        }
        .padding()
        .sheet(isPresented: $showsPaywall) { paywallSheet }
    }

    /// Stand-in for the app's own gate: a paywall today, a provider's
    /// OAuth page on iOS 27. The selector returned `.deferred`; this view
    /// commits the user's choice by setting the `userSelection` binding.
    private var paywallSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Go Premium")
                .font(.title2.bold())
            Text("The cloud model is part of the premium plan. This sheet stands in for whatever flow your app needs — a paywall, a settings page, or an OAuth login for iOS 27 user-account providers.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Subscribe") {
                userHasSubscription = true
                // External commit: the selector reflects it instantly.
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

    // MARK: Configuration

    private func applyConfiguration() {
        let log = downgradeLog
        var config = AIConfiguration()
        config.enableOnDevice = enableOnDevice
        config.enablePrivateCloudCompute = enablePrivateCloudCompute
        config.developerKey = apiKey.isEmpty ? nil : apiKey
        config.developerKeyModel = model.isEmpty ? nil : model
        config.userAccounts = userAccounts
        config.preference = effectivePreference
        if notifyDowngrades {
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

    /// The user's selection (when present) leads the chain; the developer's
    /// form preference is the default until the user picks something.
    private var effectivePreference: ModelPreference {
        switch userSelection {
        case .onDevice:
            return .preferOnDevice
        case .openAI, .anthropic, .gemini:
            return .preferDeveloperKey
        default:
            return preference
        }
    }
}
