//
//  macOSDemoApp.swift
//  macOSDemo
//
//  macOS demo for VoltaSDK — the signed counterpart to Examples/iOSDemo.
//  All the UI is shared with the iOS demo: it lives in the package's
//  VoltaSDKDemoUI target. This file is only the macOS bootstrap — plus the
//  one thing that belongs at the APP layer, exactly as it would in a real
//  adopter: wiring an OFFICIAL VENDOR PACKAGE into the chain.
//
//  Here that's Anthropic's ClaudeForFoundationModels: its ClaudeLanguageModel
//  conforms to Apple's LanguageModel protocol, so it joins VoltaSDK's chain
//  through AIConfiguration.customModels. Auth is developer-provisioned
//  (.apiKey for development; App Attest or a proxy for production) — usage
//  bills the app's Anthropic workspace, not the end user.
//
//  Because the vendor package requires OS 27, THIS APP deploys to macOS 27
//  (the shared package still deploys from 26; iOSDemo is unchanged).
//

import SwiftUI
import VoltaSDK
import VoltaSDKDemoUI
#if canImport(ClaudeForFoundationModels)
import ClaudeForFoundationModels
#endif
import AppKit

@main
struct macOSDemoApp: App {
    init() {
        // Bring the window to the foreground when launched outside a full
        // app activation context.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("VoltaSDK Demo") {
            demoRoot
                .frame(minWidth: 760, minHeight: 520)
        }
    }

    /// With Anthropic's package linked, the demo gains the "official vendor
    /// package" section; without it, the plain demo builds unchanged. The
    /// guard exists because the package tracks the LATEST Xcode 27 beta SDK
    /// and can lag/lead the installed beta (observed both directions live) —
    /// detaching the dependency must never break the rest of the demo.
    private var demoRoot: DemoRootView {
        #if canImport(ClaudeForFoundationModels)
        DemoRootView(
            vendorPackageName: "Claude (official package)",
            makeVendorModels: { apiKey in
                [CustomLanguageModel(
                    ClaudeLanguageModel(name: .sonnet5, auth: .apiKey(apiKey)),
                    identifier: ProviderIdentifier("claude-package"),
                    privacyLevel: .external
                )]
            }
        )
        #else
        DemoRootView()
        #endif
    }
}
