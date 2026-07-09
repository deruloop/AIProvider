# Changelog

All notable changes to this package. Versioning: [SemVer](https://semver.org).
**Pre-1.0 policy:** VoltaSDK is in active development — 0.x minor versions may
evolve the API. **1.0.0 will mark the complete feature set**, including the
iOS 27 extension (multi-provider, PCC, Dynamic Profiles bridge).

## [Unreleased] — iOS 27 extension (`xcode27` branch)

> Work toward the `1.0` line. Requires **Xcode 27** (iOS 27 SDK) to build;
> `@available(iOS 27, *)` keeps the deployment target at iOS 26, so adopters on
> Xcode 26.4 keep using `0.3.5`. Not yet released.

- **Private Cloud Compute provider (D6).** New `PrivateCloudComputeProvider`
  wraps `PrivateCloudComputeLanguageModel` behind the existing `ModelProvider`
  surface: Apple's free "powered" tier — no key, no account, a per-user daily
  quota — at privacy level `.appleCloud` (between on-device and the developer
  key). `availability()` reads the quota **proactively** (`quotaUsage`) and
  pre-skips an exhausted PCC; a quota that runs out mid-call surfaces as the
  recoverable `.rateLimited(retryAfter:)` (from the quota's `resetDate`), so the
  chain steps down automatically. Enabled by default via
  `AIConfiguration.enablePrivateCloudCompute`; joins the `.preferOnDevice` /
  `.preferDeveloperKey` chains, never the strict `…Only` modes. Wired into
  `buildProviders` at a single type-level `@available` gate (D14). New
  `ProviderIdentifier.privateCloudCompute`. **Validated end-to-end on an M2
  Mac (macOS 27): with the entitlement assigned, PCC answers live at privacy
  level `appleCloud`.**
- **Entitlement safety.** Calling PCC without the
  `com.apple.developer.private-cloud-compute` entitlement is a *fatal trap* in
  the framework (not a catchable error), and `availability` does not reflect a
  missing entitlement. Since PCC is default-on, `availability()` now verifies
  the running binary carries the entitlement (`SecTask` self-check) and reports
  `.unavailable` when it does not — a missing entitlement degrades to a graceful
  fallback instead of crashing the app. Confirmed against macOS 27 beta.
- **Entitlement safety, part 2 — gate at construction.** Observed live: in a
  long-running unentitled app, merely *instantiating*
  `PrivateCloudComputeLanguageModel` starts background status machinery that
  eventually traps on a background thread (`EXC_BREAKPOINT`) — beyond the reach
  of any call-site guard. The provider now runs the `SecTask` check at `init`
  and never creates the model in an unentitled process (the entitlement is
  signature-baked, so an init-time decision is sound). Fixes a crash where a
  default-on PCC took down an unentitled app minutes into a session.
- **Internal:** transcript construction shared between the on-device and PCC
  providers in a new `FoundationModelsTranscript` helper (no behaviour change
  for on-device).
- The high-priority iOS 27 open questions are now answered directly from the
  iOS 27 SDK and documented in `docs/iOS27-Design.md` §8.
- **User-account cloud providers via the `LanguageModel` front door (iOS 27).**
  The user's own OpenAI/Claude/Gemini account can join the fallback chain through
  Apple's public `LanguageModel` protocol (WWDC session 339).
  `CloudAccountLanguageModel` conforms via a `LanguageModelExecutor` that
  decomposes the framework `Transcript` into VoltaSDK's `(instructions, history,
  prompt)` shape and reuses the existing REST client (honouring per-call
  `generationOptions`; mapping to built-in `LanguageModelError` where faithful).
  `LanguageModelProvider` wraps any `LanguageModel` into the chain (via a
  `LanguageModelSession`). New `AIConfiguration.userAccounts`/`UserAccount`,
  `ProviderIdentifier.userAccount(_:)`, a "Your accounts" section in the demo,
  and a friendly picker label. The credential is a **per-call token provider**
  (static key, Keychain, or OAuth token) living on the model, off the hashable
  executor config (session 339). *Foundation: the OAuth flow itself isn't wired;
  no streaming/reasoning-level; unverified against live keys on a device.*
- **Managed OAuth for user accounts — new `VoltaSDKAuth` module.** Automates the
  whole runtime sign-in so the developer's side is "register your app once →
  paste a client ID → enable": `OAuthAccount` runs `ASWebAuthenticationSession`
  + PKCE (RFC 7636), exchanges the code, stores the token in the Keychain, and
  refreshes it silently; `OAuthConfiguration` carries the endpoints/client ID
  the developer registered with the provider; `UserAccount(oauth:)` bridges it
  into the chain (the executor's token-provider seam). Kept out of the headless
  core because it uses AuthenticationServices/Keychain. *The one irreducible
  step is the developer's: each app must be its own registered OAuth client
  (client ID + redirect) — a shared/SDK-wide client is against provider terms.*
  **Validated live against Google** (real client, real sign-in, token issued,
  stored, refreshed) and hardened from what live testing surfaced: the session
  completion is built `nonisolated` — `ASWebAuthenticationSession` invokes it
  on a background XPC queue, and a main-actor-inherited closure traps at entry
  under Swift 6's dynamic isolation checking (`EXC_BREAKPOINT` before any of
  our code runs); continuation resumption is one-shot;
  `OAuthConfiguration.additionalAuthorizationParameters` carries provider
  quirks (Google: `access_type=offline` or no refresh token is ever issued,
  `prompt=consent` to re-show granular consent); and granted scopes from the
  token response are validated at sign-in — under-granting (granular consent,
  stripped scopes) throws `scopesNotGranted(missing:granted:)` at the door
  instead of failing later at the first API call.
- **Vendor packages plug in: `AIConfiguration.customModels` (iOS 27).** The
  official vendor route Apple announced — Google ships Gemini for the
  Foundation Models framework via its Firebase SDK, Anthropic publishes a
  Claude package — lands in the chain through a new public plug-in point: any
  conformance to Apple's `LanguageModel` protocol, wrapped as
  `CustomLanguageModel(model, identifier:, privacyLevel:)`, becomes one more
  provider (statuses, picker, provenance, privacy disclosure included), no
  VoltaSDK release needed per vendor. Custom models trail the built-in
  providers in the prefer chains and are never auto-selected. (Implementation:
  the internal `LanguageModelProvider` wrapper is now existential-based, and
  the config stores entries type-erased so the iOS-27-only type stays behind an
  availability-gated accessor.)
- **Gemini: credential-aware dual transport.** A Google API key (`AIza…`)
  speaks the Developer API (`generativelanguage`, `x-goog-api-key` header) as
  before. An OAuth user token turned out to need a *different transport*, not
  just a different header: `generativelanguage` rejects user tokens for
  generation regardless of granted scopes (observed live), so `GeminiProvider`
  routes OAuth credentials to the Code Assist endpoint
  (`cloudcode-pa.googleapis.com` — the one behind Google's own Gemini CLI
  sign-in), including its `loadCodeAssist`/`onboardUser` handshake and
  `{model, project, request}` envelope. 401/403 responses surface Google's own
  message verbatim. **Provider-policy finding:** that endpoint is a private
  API, visible/enable-able only to Google's own client projects — with a
  third-party OAuth client, personal-account Gemini *generation* stays gated
  (a valid, correctly-scoped token is not enough). User-account Gemini
  generation is served by the user's API key instead; the OAuth transport is
  in place for contexts where the API is available to the client's project.
- **`ModelSelector` now auto-selects PCC (VoltaSDKUI).** The gate-free
  auto-select candidate was hardcoded to on-device, so with on-device disabled
  the selector picked nothing even when Private Cloud Compute was available.
  Generalized to the best available **gate-free** provider in chain order
  (`isGateFree` = on-device or PCC); gated providers stay non-preselected, and
  with none available the row shows "Choose a model". Added a default label for
  PCC. The demo's `onSelection` treats PCC as free (no paywall).
- **PCC access documented (Q14).** The entitlement is developer-side
  (`com.apple.developer.private-cloud-compute`), requested from Apple
  (App Store Small Business Program, < 2M downloads); adopting VoltaSDK without
  PCC requires nothing. See the README's Private Cloud Compute section.
- **Demo apps restructured — one signed Xcode app per platform.** Removed the
  unsigned `swift run VoltaSDKDemo` executable (a `swift run` binary can't carry
  the PCC entitlement) and added **`Examples/macOSDemo`**, the signed macOS
  counterpart to `Examples/iOSDemo`, running the same shared `VoltaSDKDemoUI`
  chat UI. Both demos treat PCC as **opt-in**: they build for everyone with PCC
  unavailable, and you enable live PCC by adding the capability with your own
  entitled team. (The transitional `Examples/macOSPCCTest` was folded into
  `macOSDemo`.) The shared developer pane gained a **Private Cloud Compute
  toggle** (`AIConfiguration.enablePrivateCloudCompute`) alongside the on-device
  toggle. `VoltaSDKDemoUI` library is otherwise unchanged.

## [0.3.5] — 2026-06-13

- Documentation only, no code changes: the SPM installation snippet now uses
  the real public repository URL.

## [0.3.4] — 2026-06-13

- Documentation only, no code changes: the public README no longer
  describes the unimplemented iOS 27 extension (multi-provider, PCC,
  Dynamic Profiles, OAuth user-account flows) — there is no iOS 27 code
  yet, so the forward-looking references were noise for adopters. The
  internal design docs (`docs/iOS27-Design.md`,
  `docs/iOS27-OpenQuestions.md`) keep the full design and remain linked
  from the README's contributors section.

## [0.3.3] — 2026-06-13

- Documentation only, no code changes: the build requirement is now stated
  precisely. **Building requires Xcode 26.4+** — the token-counting API the
  26.4 tier references is declared only in the 26.4 SDK, and the
  `#available` gate is a runtime check, so older toolchains (e.g. a CI
  runner pinned to Xcode 26.0.x) fail to compile the package. Running still
  requires only iOS/macOS 26.0. The CI symptom and the reason this is not
  worked around with compile-time conditionals (it would silently strip the
  token-aware tier) are documented in the implementation doc's
  troubleshooting notes.

## [0.3.2] — 2026-06-13

- **`ModelSelector` no longer lets a configuration look like a user
  activation (gate invariant):** nothing is ever committed without passing
  through `onSelection`, including the initial state. With a nil
  `selection` binding the selector auto-selects the on-device model iff
  available — the only gate-free provider — running even that through the
  handler; cloud providers are **never preselected**. Fixes the state where
  a developer-key-first configuration appeared "already active" without the
  entitlement gate ever firing. A non-nil initial binding (persisted user
  choice) is never overridden.
- Demo: the chat is disabled until a model is committed, demonstrating the
  `selection == nil` ("no model committed") contract that keeps gated
  providers from answering before activation.

## [0.3.1] — 2026-06-12

- Documentation text adjustments only; no code changes.

## [0.3.0] — 2026-06-12

- **`ModelSelector` redesigned as a collapsed disclosure:** resting state is
  a single row with the active choice; tapping expands the options. Scales
  to the longer iOS 27 provider list.
- **Selection is now a three-way response** (`ModelSelectionResponse`):
  `.activate`, `.deny(message:)`, or `.deferred` — the app takes over with
  its own view (paywall, settings, future OAuth page) and commits later by
  setting the `selection` binding. Replaces the boolean `activation:` hook.
- Default labels no longer claim "included with your subscription" — the
  component makes no business assumptions; brand rows via `labels:`.
- Demo: the developer-model field now appears as a consequence of entering
  a key (scoped to the detected vendor, with that vendor's catalog link);
  the cloud-model selection demonstrates the `.deferred` path with a
  paywall sheet that commits externally.
- Migration from 0.2.0: replace `activation: { … true/false }` with
  `onSelection: { … .activate / .deny() }`; `showsActiveBadge` was removed
  (the collapsed row itself is the confirmation).

## [0.2.0] — 2026-06-12

- **Multi-vendor developer key (D15):** the `developerKey` slot now accepts
  OpenAI, Anthropic (Claude), or Google (Gemini) keys. The vendor is
  auto-detected from the key format (`sk-ant-…`/`AIza…`/`sk-…`), overridable
  via `developerKeyVendor`. New `AnthropicProvider` and `GeminiProvider`
  with the same typed errors, history mapping (D12), and token awareness
  (D13) as the OpenAI provider.
- `developerKeyModel` is now optional (`nil` = the vendor's default model)
  and no longer pre-filled in the demo: the model name belongs to the key's
  vendor. `CloudVendor.modelDocumentationURL` links to each vendor's model
  catalog; the demo surfaces detection and the links.
- Demo: keyboard now dismisses interactively by scrolling everywhere.
- Migration from 0.1.0: if you set `developerKeyModel`, the type changed
  from `String` to `String?` — existing assignments keep compiling; only
  reads need unwrapping.

## [0.1.0] — 2026-06-12

Initial development release: the full iOS 26 / macOS 26 base, Swift 6.2.
(Consolidates the earlier internal iterations, including the rename from the
AIProviderKit working title to **VoltaSDK** — *Versatile Orchestration Layer
for Tiered AI* — and the full English translation.)

### Core (`VoltaSDK`)
- `AIOrchestrator`: runtime fallback chain across providers, with typed
  errors (`ProviderError`) and the recoverable/terminal distinction.
- Bundled providers: `OnDeviceProvider` (Foundation Models, Apple
  Intelligence) and `OpenAIProvider` (developer key, Chat Completions).
- Privacy-downgrade disclosure (`PrivacyDisclosure`):
  `.silent` / `.notify` / `.askOnPrivacyChange` / `.denyDowngrade` (D10).
- Transcript-transparent multi-turn conversations (D12): the core is
  stateless, the app passes the history (`history: [ChatTurn]`) on every
  call; fallback works mid-conversation.
- Token awareness (D13): automatic context-window pre-flight (exact
  on-device counting from iOS/macOS 26.4, honest estimates for cloud
  providers) and `contextUsage(instructions:history:)` to decide when to
  trim the history.
- Resolution primitive `resolveProvider()` (D9) and response provenance
  (`respondDetailed` → provider + privacy level).
- Public `MockProvider` for testing integrations without network or device.

### Optional UI (`VoltaSDKUI`)
- `ModelSelector`: drop-in **user-side** model picker with an "active"
  confirmation badge and a developer `activation` gate (paywall /
  entitlement checks today; OAuth flows for iOS 27 user-account providers
  through the same hook). Customizable labels, flags, and a public row.
- `PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
  `AIPlaygroundView` (conversational, with a context-pressure indicator).

### Demos
- macOS (`swift run VoltaSDKDemo`) and iPhone/iPad
  (`Examples/iOSDemo/iOSDemo.xcodeproj`), sharing one adaptive UI split into
  a Developer side (configuration) and a User side (chat + `ModelSelector`).

### Verification
- 34 tests in 7 suites; builds verified on macOS 26.5, the iOS 26.5
  simulator, and a physical iPhone (signing).
