# VoltaSDK — Project Context

> Entry point for working on this project. The detailed documentation is split
> into dedicated artifacts (map below); this file holds the working agreement,
> the current state, and the roadmap.
> **Working agreement: every code change must update the relevant doc(s) in the
> same session** — this index, the implementation/design docs, and CHANGELOG on
> release. (Language note: **everything is in English** — docs, code comments,
> and user-facing strings — as of v1.0.1.)

---

## 1. TL;DR — what this is

VoltaSDK (**VOLTA** = *Versatile Orchestration Layer for Tiered AI*; named
after Alessandro Volta — battery = stacked cells = fallback chain) is a
Swift Package that **resolves
which AI model to use** at runtime (on-device Foundation Models vs a
vendor-agnostic developer key — OpenAI, Claude, or Gemini — today; PCC and
user-account providers on iOS 27) with
automatic fallback, privacy disclosure, transcript-transparent conversations,
and token awareness. It does **not** invent an agent abstraction — on iOS 27
it *feeds* Apple's native Dynamic Profiles rather than wrapping them. One
stable public API across all phases (SemVer: 0.x during development; **1.0.0
is reserved for the complete feature set, including iOS 27**).

## 2. Documentation map

| Artifact | Audience | Content |
|---|---|---|
| `README.md` | public (GitHub) | what it is, **version support tiers (26.0 / 26.4 / 27)**, SPM installation, usage, demos |
| `docs/iOS26-Implementation.md` | internal | how the **shipped** iOS 26 + 26.4 tiers are implemented: file map, decisions D4–D5, D7–D13, D15, stable API, verification, troubleshooting |
| `docs/iOS27-Design.md` | internal | how iOS 27 **will** be implemented: decisions D1–D3, D6, D14, capability split, provider table, mapping, implementation order |
| `docs/iOS27-OpenQuestions.md` | internal, temporary | Q1–Q17 gating iOS 27 work; answers get merged into the design doc, then this file is deleted |
| `CHANGELOG.md` | public | SemVer release notes |

Rule of thumb: change shipped code → update the iOS 26 doc; take an iOS 27
decision → update the design doc; learn an iOS 27 answer → move it from the
questions doc into the design doc; release → CHANGELOG + state here.

## 3. Current state (June 2026)

- **Versioning policy (user decision, June 2026): 1.0.0 is reserved for the
  complete feature set, including iOS 27.** The earlier 1.0.0/1.0.1/2.0.0
  tags were deleted (never pushed anywhere); current release line is **0.x**,
  starting at `0.1.0`. During 0.x, minor versions may evolve the API.
- **iOS 26 / 26.4: fully working — v0.3.5** (tags `0.1.0`–`0.3.5`,
  2026-06-12/13; 0.2.0 = vendor-agnostic developer key D15, 0.3.0 = collapsed
  ModelSelector with `.activate/.deny/.deferred` selection responses,
  0.3.1 = docs-only, 0.3.2 = ModelSelector gate invariant — never preselects
  gated providers, auto-selects on-device only, through `onSelection`,
  0.3.3 = docs-only: **builds require Xcode 26.4+** / runs on 26.0+,
  learned from an adopter's CI failure,
  0.3.4 = docs-only: public README stripped of iOS 27 forward-references
  (design docs keep them; nothing iOS 27 is implemented),
  0.3.5 = docs-only: real repo URL in the SPM snippet).
  **0.3.5 is the stable iOS 26 line and the designated Xcode-26.4 anchor**
  (the last release that compiles with Xcode 26.4 — the iOS 27 line will
  require Xcode 27).
  41 tests in 8 suites green; builds verified on macOS 26.5, iOS 26.5
  simulator, and signed for a physical iPhone. First adoption in the author's
  app is in progress. The 26.4 token-aware tier lights up by itself at
  runtime; on 26.0–26.3 context handling stays reactive-only, by design.
- **iOS 27: implementation STARTED on `xcode27` (June 2026).** The hard gate
  is cleared — Xcode 27 beta (27A5209h) + iOS 27.0 SDK are installed at
  `/Applications/Xcode-beta.app` (build with
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build|test`;
  the machine's default `xcode-select` is still Command Line Tools). The
  package builds and tests green on the beta (Swift 6.4, macOS 27 SDK on the
  host, **44 tests in 9 suites**). First provider shipped on the branch:
  **`PrivateCloudComputeProvider`** (`@available(iOS 27, *)`, wired into
  `buildProviders` at one gate per D14, default-on via
  `enablePrivateCloudCompute`, placed between on-device and the developer key
  in the two `prefer` chains). **Validated end-to-end on the M2 host (macOS 27):
  with the entitlement assigned to the account, PCC answers live at privacy
  `appleCloud`.** Key runtime findings folded in: the required entitlement is
  `com.apple.developer.private-cloud-compute` (developer-side; requested via
  Apple's form, Small Business Program + <2M downloads); `availability` is NOT
  entitlement-aware and a missing entitlement *traps* (uncatchable) on first
  `respond`, so the provider gates on a `SecTask` self-check and degrades to a
  graceful skip (matters because PCC is default-on — adopting VoltaSDK never
  forces the entitlement). High-priority open questions answered from the SDK
  and folded into `docs/iOS27-Design.md` §8 (Q1–Q7, Q9–Q11, Q14); what remains
  (`docs/iOS27-OpenQuestions.md`: Q8, Q12–Q13, Q15–Q17) needs external accounts,
  a separate package, or more runtime poking — not API shape.
- **Demos restructured (June 2026): one signed Xcode app per platform.**
  Dropped the unsigned `swift run VoltaSDKDemo` executable (a `swift run` binary
  can't carry the PCC entitlement) and added **`Examples/macOSDemo`** — the
  signed macOS twin of `Examples/iOSDemo`, same shared `VoltaSDKDemoUI` chat UI.
  Both treat PCC as **opt-in** (build for everyone, PCC unavailable; enable live
  PCC by adding the capability with your own entitled team). The transitional
  `Examples/macOSPCCTest` was folded into `macOSDemo`. **XcodeGen 2.33 caveat:**
  it emits local packages as a legacy folder reference that Xcode 27 rejects
  ("Missing package product"); both demo `.xcodeproj` are hand-patched to use
  `XCLocalSwiftPackageReference` and are the source of truth — re-apply that fix
  if you regenerate.
- **Git: remote is `https://github.com/deruloop/VoltaSDK.git` (public).**
  Branching strategy (user decision, June 2026):
  - **`main`** = the iOS 26 line. Stays at `0.3.x` (now `0.3.5`), builds on
    Xcode 26.4+, runs on iOS 26+. Public README describes only this.
  - **`xcode27`** (pushed, currently identical to `main`) = the iOS 27 work.
    Requires Xcode 27 (iOS 27 SDK); `@available(iOS 27, *)` so it still
    deploys to iOS 26+. **Merged into `main` when iOS 27 ships (~September),
    at which point `main` becomes the `1.0` line.** Periodically sync
    `main → xcode27` to avoid drift. Its README will advertise the Xcode 27
    requirement and point Xcode-26.4 users to pin `0.3.5`.
  - Toolchain note (settled): no `#if canImport` gymnastics needed. The
    iOS-27 release simply *requires Xcode 27 to build* (documented like the
    26.4 note); `@available` handles runtime; deployment target stays iOS 26;
    adopters on older Xcode pin to `0.3.5`. SemVer covers the rest.

### ACTIVE WORK — iOS 27, resume here (June 2026)
Implementing iOS 27 by **learn-by-building** against the real SDK. Done so far
on `xcode27`: hard gate cleared; SDK read directly (the `.swiftinterface` is
the source of truth — see `docs/iOS27-Design.md` §8); high-priority open
questions answered; **`PrivateCloudComputeProvider`** built, wired, unit-tested,
and **validated live on the M2 host (macOS 27) with the entitlement assigned**;
demos restructured to one signed Xcode app per platform (`iOSDemo` + new
`macOSDemo`), PCC opt-in; public README documents the PCC entitlement.

Note on the earlier plan: it expected to scaffold `Examples/iOS27Demo` and
leave the core "clean," and to treat the PCC provider as a stub because Q1–Q4
"need a device." Reading the `.swiftinterface` made the API shape (incl. the
full quota/error surface) discoverable *by compiling*, so the PCC provider went
straight into the core target behind a type-level `@available` gate (the D14
end state). Only the runtime *values/behaviour* still need a device.

Next steps, in order:
1. **User-account OpenAI/Claude/Gemini** via the `LanguageModel` + `Executor`
   pattern (§8) — **FOUNDATION BUILT (xcode27, uncommitted demo + committed
   core `5e1ebdf`/`067ccf1`).** `CloudAccountLanguageModel` (one vendor-agnostic
   `LanguageModel` keyed by `CloudVendor`) drives the existing REST clients via
   `FoundationModelsTranscript.decompose`, honours per-call `generationOptions`,
   maps to `LanguageModelError` where faithful. `LanguageModelProvider` wraps a
   `LanguageModel` into the chain (via `LanguageModelSession`).
   `AIConfiguration.userAccounts`/`UserAccount` + `ProviderIdentifier.userAccount(_:)`
   wired into `buildProviders` at one `@available` gate; demo has a "Your
   accounts" section. **Auth:** credential is a per-call **token provider**
   (`UserAccount.token` / `CloudAccountLanguageModel.token`, static-key
   convenience kept) living on the model — off the hashable executor
   `Configuration` per 339; the shared `LanguageModelError` mapper is extracted
   (`ProviderError(_:)`). **OAuth is automated** by the new **`VoltaSDKAuth`**
   module (`OAuthAccount`: `ASWebAuthenticationSession` + PKCE + Keychain +
   silent refresh + granted-scope validation; `OAuthConfiguration` incl.
   `additionalAuthorizationParameters`; `UserAccount(oauth:)` bridge) — kept
   out of the headless core. The irreducible step stays the developer's: each
   app is its own registered OAuth client. **VALIDATED LIVE against Google**
   (July 2026, real client on the M2): sign-in → PKCE → token → Keychain all
   work. Key findings: `ASWebAuthenticationSession` calls its completion on a
   background XPC queue → a main-actor-inherited closure traps under Swift 6
   dynamic isolation (fixed: `nonisolated` completion factory); Google needs
   `access_type=offline` (else no refresh token) + `prompt=consent`; granular
   consent can under-grant → validated at sign-in (`scopesNotGranted`).
   **Gemini OAuth generation is provider-policy-gated:** `generativelanguage`
   rejects user tokens regardless of scopes; the accepting endpoint
   (`cloudcode-pa`, Gemini CLI's) is a private API not enable-able for
   third-party client projects — `GeminiProvider` now has the dual transport
   (key → Developer API, OAuth → Code Assist envelope) for contexts where it
   is available, and user-account Gemini generation otherwise = the user's API
   key. **Cross-vendor verdict (verified online, July 2026): the same policy
   holds for all three** — Anthropic restricts Claude Free/Pro/Max OAuth to its
   own products (sanctioned alternative: Agent SDK credits, i.e. *their* SDK);
   OpenAI's "Sign in with ChatGPT" is identity-only. The demo's connect flow is
   therefore **key-only** (sign-in removed; `VoltaSDKAuth` retained as
   general-purpose machinery, demo no longer depends on it).
   **The official vendor route is the vendor's own package** (Gemini via
   Google's Firebase SDK; Anthropic's `ClaudeForFoundationModels`, verified
   available: github.com/anthropics/ClaudeForFoundationModels, v0.1.0+,
   developer-billed via `.apiKey`/`.appAttest`/`.proxied` — user-subscription
   Claude is Agent-SDK-only, a different surface) — supported via the new
   public **`AIConfiguration.customModels`** plug-in point
   (`CustomLanguageModel` wraps any Apple `LanguageModel` into the chain; the
   internal `LanguageModelProvider` is existential-based; type-erased config
   storage keeps the iOS-27 type behind a gated accessor).
   **FRONT DOOR VALIDATED LIVE (August 2026, beta 27A5237l):** a
   user-connected Gemini account (API key via the connect sheet) answered in
   `macOSDemo` through the full path — chain → `LanguageModelProvider` →
   `LanguageModelSession` → the `CloudAccountLanguageModel` executor →
   transcript decompose → REST; the whole package also builds clean on the new
   beta (no SDK drift). Demo hook for vendor packages shipped:
   `DemoRootView.init(vendorPackageName:makeVendorModels:)` + an "Official
   vendor package" section; `macOSDemo` (deployment now macOS 27; iOSDemo
   still 26) wires `ClaudeForFoundationModels` behind `#if canImport`, **SPM
   dependency parked** (commented in project.yml, removed from pbxproj): beta
   version skew broke it in both directions (0.1.4 targets beta 3 — failed vs
   the June beta on `SamplingMode`, vs 27A5237l on `Transcript.CustomSegment`).
   Re-attach when Anthropic ships a matching release; the section lights up by
   itself. **Toolchain: beta 27A5237l at `~/Downloads/Xcode-beta.app`.**
   **Still to do (Part 2 leftovers, deferred by design):** Claude-package live
   validation once re-attached, real streaming, reasoning level, resolve the
   chain transcript round-trip. Article draft:
   `docs/articles/bringing-cloud-models-front-door.md` (git-excluded). The
   Utilities Chat-Completions `LanguageModel` (Q8) is still unchecked — proceeded
   hand-written.
2. **`preferred(_ need:) -> any LanguageModel`** bridge (D1/D9): evolve
   `resolveProvider()` to return Apple's `LanguageModel` (confirmed feedable to
   `.model(_:)` and `LanguageModelSession(model:)`, §8) for native Dynamic
   Profiles. Needs each VoltaSDK provider to expose/wrap an `any LanguageModel`.
3. **Per-need fallback chain** (`.lightweight/.reasoning/.largeContext`),
   keeping `ModelPreference` at 4 cases (a third tier makes the closed enum
   combinatorial).
4. **Follow-up surfaced by §8:** generalize the D13 `contextSize` capability
   from sync `Int?` to an async read, so PCC/cloud models can join the
   proactive token pre-flight (today PCC opts out → reactive only).
5. **Deeper PCC runtime validation:** live answering is confirmed (via
   `Examples/macOSDemo`, signed with the granted entitlement). Still to observe
   on a device: real quota-exhaustion (`.quotaLimitReached` → `.rateLimited`
   mapping) and `serviceUnavailable`, then fold Q15 (dev vs prod quotas) and
   any Q12/Q13 findings into the design doc. Confirmed so far: `availability`/
   `quotaUsage` read fine *without* the entitlement, but the first `respond`
   traps if it's absent — hence the provider's `SecTask` self-gate.

Design decision already recorded under D7 in `docs/iOS27-Design.md`:
**`.largeContext` is REACTIVE, not preemptive** — it reorders the chain to
favour large-window providers but does NOT hard-route to cloud; on-device still
answers any call that actually fits, and the handoff fires only when the token
pre-flight shows real overflow. Privacy crossings stay driven by measured
overflow, never inferred from the need.

## 4. Core principles (one-liners; full rationale in the linked docs)

- **D1/D2** Feed Dynamic Profiles, never own "agent" — we do model resolution. *(27 design)*
- **D3** One stable API; iOS 27 lights up additively. *(27 design)*
- **D4** Developer key = AI included in the app's subscription. *(26 impl)*
- **D5** On-device is never assumed present. *(26 impl)*
- **D6** PCC = free tier with runtime-exhaustible quota → fallback must be runtime. *(27 design)*
- **D7** Per-call re-resolution + privacy threshold disclosure. *(both)*
- **D8** Type is `AIOrchestrator` (module/type shadowing). *(26 impl)*
- **D9** `resolveProvider()` is the primitive; `respond` is convenience. *(26 impl)*
- **D10** Privacy disclosure shipped in 26, not 27. *(26 impl)*
- **D11** UI optional by construction; core never imports SwiftUI. *(26 impl)*
- **D12** Stateless core, transcript-transparent: app owns history, every call self-contained. *(26 impl)*
- **D13** Token awareness as optional capability + orchestrator pre-flight. *(26 impl)*
- **D14** One package, three capability tiers — expression-level gates for 26.4, type-level gates for 27. *(27 design)*
- **D15** Vendor-agnostic developer key: OpenAI/Claude/Gemini in one slot, auto-detected; model name travels with the key. *(26 impl)*

## 5. Roadmap (ordered)

1. ~~Compile & green the tests~~ ✅
2. ~~Privacy disclosure~~ ✅ (D10)
3. **Streaming.** Add `streamResponse` to `ModelProvider` and both providers
   (OpenAI via SSE `"stream": true`). Design question: stream vs fallback
   (fail before first token = fall through; fail mid-stream = surface).
4. ~~Token/context awareness~~ ✅ (D13)
5. ~~Multi-turn~~ ✅ (D12) — still open, lower priority: KV-cache/`Transcript`
   reuse when the provider didn't change between turns; trimming hook pairs
   with `contextUsage`.
6. **iOS 27 providers** — PCC ✅ (xcode27, structural; runtime unverified);
   user-account Gemini/Claude next via the `LanguageModel`+`Executor` pattern
   (`docs/iOS27-Design.md` §6/§8). Was blocked; SDK now in hand.
7. **Per-need fallback chain** (`.lightweight/.reasoning/.largeContext`) —
   unblocked with 6; not started.
8. **`preferred(_ need:)` bridge** for Dynamic Profiles — unblocked with 6
   (returns `any LanguageModel`, feedable to `.model(_:)`, §8); not started.
9. ~~Model picker component~~ ✅ (June 2026): `ModelSelector` in VoltaSDKUI —
   collapsed user-side picker; selection answered by the app with
   `.activate`/`.deny`/`.deferred` (deferred = app-owned flow commits later
   via the binding — the iOS 27 OAuth-page pattern). Gate invariant: nothing
   commits without `onSelection` — auto-selects the best available **gate-free**
   provider (on-device, or PCC when on-device is off/unavailable; `isGateFree`
   = `{.onDevice, .privateCloudCompute}`), in chain order; gated providers
   (developer-key, user-account) are never preselected. iOS 27 providers appear
   automatically once wired into `buildProviders`; PCC has a default label.
10. **Fetch model lists from vendor APIs** (OpenAI/Anthropic `GET /v1/models`,
    Gemini `ListModels`): once a key is entered, populate a model picker for
    the developer instead of a free-text field. Complements D15.
