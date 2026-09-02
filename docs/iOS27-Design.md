# VoltaSDK — iOS 27 Design (internal source)

> Internal documentation of the **iOS 27 extension: in progress on the
> `xcode27` branch**. As of June 2026 the first provider —
> `PrivateCloudComputeProvider` — is implemented and compiles/tests green
> against the real iOS 27 SDK (Xcode 27 beta, build 27A5209h); its runtime
> behaviour still needs an Apple-Intelligence device with the PCC entitlement.
> This file holds everything we know and have decided. **§8 records what was
> verified directly against the SDK** (the source of truth for API shape); the
> remaining open questions live in `docs/iOS27-OpenQuestions.md` and are merged
> back here as they are answered. The shipped iOS 26/26.4 implementation is
> documented in `docs/iOS26-Implementation.md`.

---

## 1. The plan in one paragraph

On iOS 27 Apple opens the Foundation Models stack: a public `LanguageModel`
protocol (multi-provider), `PrivateCloudComputeLanguageModel` (PCC), and
Dynamic Profiles (declarative agents). VoltaSDK's job stays the same —
**model resolution** — but the chain grows: on-device, PCC, developer key, and
user-account providers (Gemini/Claude), selected per call by need, auth, quota,
availability, and privacy policy. The public API does not change: iOS 27
features are additive (SemVer: within the current major, 2.x).

## 2. Founding decisions

### D1 — Feed Dynamic Profiles, don't abstract them
Apple's Dynamic Profiles (iOS 27) are already a clean, SwiftUI-style declarative
API for agents (`struct …: LanguageModelSession.DynamicProfile` with a `body`
and result builder, using `.model(...)`, `.temperature(...)`,
`.reasoningLevel(...)`). Building a parallel declarative layer on top would
fight the framework and always be less expressive. **Our value is model
resolution**, which Apple does *not* provide: given user choice + auth + quota
+ device support, return the concrete `LanguageModel`. The developer writes
Dynamic Profiles natively and writes e.g.
`.model(orchestrator.preferred(.reasoning))`.

### D2 — No custom `Agent` class
Rejected an `Agent(id:instructions:tools:)` abstraction: it would become a weak
duplicate of Dynamic Profiles carried for years for back-compat. The framework
never owns the concept of "agent" — it only owns model resolution.

### D3 — iOS 26 base + iOS 27 extension, one stable API
Ship value now on iOS 26 while designing the public surface to be exactly what
iOS 27 needs. iOS 27 features light up when available; absent silently on
iOS 26. No app rewrite on upgrade. Build target is iOS 26 only until the iOS 27
SDK is adopted.

### D6 — PCC is the "free powered" tier
Private Cloud Compute: a large server model that integrates like on-device —
**no auth, no API key**, built into the OS with iCloud. Free for the developer
(apps <2M downloads, apply on the developer website). Per-user **daily quota**,
higher with iCloud+. Crucial implication: **PCC quota can run out mid-use at
runtime** — the main reason the fallback must be automatic and runtime, not a
static setup choice.

**Update (verified in the SDK, §8):** the quota is *also* readable
**proactively** — `PrivateCloudComputeLanguageModel.quotaUsage`
(`isLimitReached` / `isApproachingLimit` / `resetDate`). So the runtime
fallback stays the safety net (quota can still flip mid-call → a distinct
`.quotaLimitReached` error), but `PrivateCloudComputeProvider.availability()`
*pre-skips* an already-exhausted PCC without paying for a doomed round-trip.
Both paths exist; neither replaces the other.

### D7 (iOS 27 part) — Per-need chains + disclosure
The developer expresses a *need* (`.lightweight` / `.reasoning` /
`.largeContext`); behind it is an ordered fallback chain the framework walks at
runtime, scaling automatically on recoverable failure (quota, network, auth
expiry). Each model has a privacy rating; crossing the privacy threshold
(e.g. PCC → external provider) triggers the disclosure policy — already shipped
in iOS 26 (see D10 in the iOS 26 doc), so on iOS 27 it only gains the
`.appleCloud` level in practice.

**`.largeContext` is reactive, not preemptive (decided June 2026).** The need
reorders the chain to *favour* large-window providers, but it does **not**
hard-route to cloud. The need shapes ordering; the existing token pre-flight
(D13) decides the per-call handoff. On-device still answers any call that
actually fits; the transition to a larger-context provider fires only when the
token count shows the on-device window would overflow — proactively on 26.4+,
reactively otherwise via `.contextWindowExceeded`. Rationale: `.largeContext`
means "this call *can* be large," not "*is* large now"; preemptively routing to
cloud would infer largeness from a hint and trigger a privacy downgrade for a
call that turned out small. The crossing must stay driven by measured overflow,
consistent with "explicit beats inferred for privacy". (Possible future opt-in:
a stricter mode that skips the on-device pre-flight when a developer *knows*
inputs are always huge — explicit, never the default.)

**Amendment (Sep 2026, user decision — supersedes the on-device-first part
above):** `.largeContext` now ranks **on-device LAST** (Apple cloud →
external, window-sorted within tiers, on-device as the final fallback).
Rationale: the small on-device model's consistency/reliability isn't trusted
for long-context work, even for calls that would fit its window. Trade-off
accepted knowingly: the hint now moves work off-device by itself (to the
`.appleCloud` tier first — still Apple, still no third party while PCC is
available), a departure from June's "a hint must never cause a privacy
crossing". What stays reactive: the D13 pre-flight still skips any provider
whose window the *measured* call exceeds, so ordering never sends a call
somewhere it can't fit.

### D14 — One package, three capability tiers — not three SDKs
- **Tier 26.0 (base):** fallback + privacy + transcript transparency; context
  handling reactive only.
- **Tier 26.4 (token-aware):** exact on-device counting, proactive pre-flight,
  `contextUsage` — gated by `if #available(iOS 26.4, *)` *inside* the
  on-device provider.
- **Tier 27 (multi-provider):** new capabilities arrive as **whole new types**
  (PCC provider, user-account providers, `preferred(_:)` bridge), each marked
  `@available(iOS 27, *)` at the type level and wired into `buildProviders`
  in one place — not `if` statements scattered through shared logic.
Rationale: small in-API deltas suit *expression-level* availability checks;
paradigm-sized deltas suit *type-level* gating, because the orchestration logic
doesn't branch — the provider list just gets longer on newer OSes. Three
separate branches/packages were rejected: combinatorial maintenance, and D3
already promises adopters one stable API where features light up.
Practical constraint: iOS 27 code physically requires the iOS 27 SDK
(Xcode beta) to compile — until then, iOS 27 remains design-only.

## 3. iOS 26 vs iOS 27 capability split

**Available in iOS 26 (base is built on this):**
- `SystemLanguageModel`, `LanguageModelSession`, `respond`, `streamResponse`
- Guided generation (`@Generable`, `@Guide`), tool calling
- Availability API (`SystemLanguageModel.default.availability`)
- LoRA adapters
- iOS 26.4: context-size inspection + token counting APIs (shipped, D13)

**Exclusive to iOS 27 (this design targets these):**
- Public `LanguageModel` protocol → multi-provider (Gemini, Claude, OpenAI)
- `PrivateCloudComputeLanguageModel` → PCC
- Dynamic Profiles → declarative agents/subagents
- Foundation Models framework **Utilities** (open-source): Skills, Profile
  Modifiers, a Chat Completions `LanguageModel`
- Vision input on the on-device model
- System tools: OCRTool, BarcodeReaderTool, Spotlight RAG

## 4. Provider reference (target state)

| Provider | Auth | Cost | Privacy | Requirement | Phase |
|---|---|---|---|---|---|
| On-device (~3B) | none | free | max (offline) | Apple Intelligence | iOS 26 ✅ |
| Developer Key — OpenAI, Anthropic, or Gemini (D15: one slot, vendor auto-detected) | dev key | dev pays | external | key configured | iOS 26 ✅ |
| Private Cloud Compute | none | free w/ daily quota | high (no storage) | Apple Intelligence + app <2M dl | iOS 27 |
| Google Gemini (user account) | OAuth (Firebase) | user tokens | provider-dependent | user account | iOS 27 |
| Anthropic Claude (user account) | user API key | user tokens | provider-dependent | user account | iOS 27 |
| OpenAI ChatGPT (user account) | user API key | user tokens | provider-dependent | user account | iOS 27 |

Note the distinction sharpened by D15: **Claude and Gemini are already
available on iOS 26 as developer-key providers** (the developer pays, REST
clients in the core). What remains iOS 27 is the **user-account** variant of
the same vendors (the user pays via OAuth/own key, through the public
`LanguageModel` protocol) — different auth and billing, same vendor. The
existing `AnthropicProvider`/`GeminiProvider` REST clients can serve as the
transport layer for the user-account variants if the Utilities' Chat
Completions `LanguageModel` (Q8) turns out not to cover them.

## 5. Mapping: what exists today → what it becomes

| iOS 26 (shipped) | iOS 27 (extension) |
|---|---|
| `OnDeviceProvider` | unchanged |
| `OpenAIProvider`/`AnthropicProvider`/`GeminiProvider` (URLSession, dev key, D15) | providers conforming to the `LanguageModel` protocol; user-account variants added |
| `ModelPreference` (4 cases, deliberately frozen) | per-need fallback chain + PCC quotas |
| `resolveProvider()` (D9) | `preferred()` ✅ (xcode27) returning a `LanguageModel` for Dynamic Profiles; per-need overload pending |
| `PrivacyDisclosure` (live since 26) | unchanged; `.appleCloud` level becomes reachable (PCC) |
| `ProviderError.isRecoverableByFallback` | PCC's `.quotaLimitReached` maps to the existing recoverable `.rateLimited(retryAfter:)`; `.serviceUnavailable`/`.networkFailure` map to recoverable `.network` (Q2/Q4 answered — no new enum case needed) |
| D13 capability surface (`contextSize`/`tokenCount`) | per-model token reading lands here (pending Q10) |
| `ChatTurn` history (D12) | answers transcript portability across providers (pending Q6/Q7 for KV-cache) |
| — | `PrivateCloudComputeProvider` ✅ (xcode27 branch: structural — compiles & tests green; runtime behaviour pending a device) |
| `ModelSelector` (VoltaSDKUI, shipped) | gains the new providers automatically; OAuth flows attach via its existing `activation` hook |
| — | user-account providers (Gemini/Claude): OAuth flow attaches via `ModelSelector`'s existing `activation` hook |

## 6. Implementation order (when unblocked)

Matches the roadmap in CLAUDE.md:
1. **`PrivateCloudComputeProvider` ✅ (June 2026, xcode27 branch).** Wraps
   `PrivateCloudComputeLanguageModel` behind the existing `ModelProvider`
   surface; proactive quota-aware `availability()`; error mapping to the
   existing `ProviderError` cases; wired into `buildProviders` at one
   `@available(iOS 27, *)` gate (D14), default-on, joining the two `prefer`
   chains between on-device and the developer key. **Next:** user-account
   Gemini/Claude via the `LanguageModel` protocol (the Executor pattern, §8),
   wired into the same place.
2. ~~Runtime fallback chain keyed on need~~ ✅ **implemented (Sep 2026,
   xcode27)** as a per-call `need:` hint that reorders the configured chain
   (stable tier sort; `.largeContext` reactive per D7, window-sorted within
   tier; verified by tests incl. the measured-overflow crossing),
   replacing/extending `ModelPreference` (kept at 4 cases on purpose — a third
   provider makes a closed enum combinatorial).
3. ~~`preferred(_ need:)` bridge for Dynamic Profiles~~ ✅ **shipped as
   `preferred()` (Aug 2026, xcode27)** — same chain walk as `resolveProvider()`
   (availability + `.denyDowngrade`), returns the winning provider's native
   `any LanguageModel` via the public `LanguageModelConvertible` capability:
   on-device → `SystemLanguageModel.default` (confirmed conforming), PCC → its
   entitled model instance (nil-gated), wrapped models → themselves, and the
   developer-key REST providers → a `CloudAccountLanguageModel` over the same
   client (generation options then belong to the consuming session/profile —
   Apple's design). Non-convertible custom providers are skipped. The
   per-need parameter (`preferred(_ need:)`) arrives with step 2's chains as
   an additive overload.
4. ~~Model picker component~~ shipped (`ModelSelector` in VoltaSDKUI): the new
   providers appear automatically once wired into `buildProviders`; their OAuth
   flows attach via the existing `activation` hook. **Done (June 2026):** PCC
   has a default label, and the deliberate revisit is implemented — the
   auto-select candidate is no longer hardcoded to on-device. `isGateFree`
   (`{.onDevice, .privateCloudCompute}`) defines the gate-free set, and
   `autoSelectIfNeeded` picks the first available gate-free provider **in chain
   order** (on-device when present, PCC when on-device is off/unavailable);
   gated providers (developer-key, user-account) are never preselected. The
   demo's `onSelection` likewise treats PCC as free (immediate `.activate`, no
   paywall). User-account vendors will stay gated (OAuth) when added.

## 7. Blockers

Implementation is gated on:
- ~~**The iOS 27 SDK** (Xcode beta)~~ ✅ resolved — Xcode 27 beta (27A5209h)
  with the iOS 27.0 SDK is installed; the package builds and tests green on it
  (Swift 6.4, macOS 27 SDK on the host).
- **The remaining open questions** in `docs/iOS27-OpenQuestions.md`. The
  high-priority block (PCC quota semantics, `LanguageModel` conformance,
  transcript portability) is now **answered from the SDK** — see §8. What
  stays open needs a real Apple-Intelligence device + PCC entitlement
  (runtime values, not API shape) or external accounts: parity-on-fallback
  (Q12/Q13), distribution (Q14–Q16), and the Utilities Chat-Completions
  model (Q8, a separate open-source package).

## 8. Verified against the iOS 27 SDK (Xcode 27 beta 27A5209h, June 2026)

Read directly from
`FoundationModels.framework/.../arm64e-apple-ios.swiftinterface` — the
authoritative API shape (more reliable than WWDC notes). Mark these
"observed in iOS 27 beta — re-verify at GA"; betas churn.

**`LanguageModel` protocol (Q9).** Conformance is via an **Executor**, not a
direct `respond`:
```
protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Self.Executor.Configuration { get }
}
protocol LanguageModelExecutor: Sendable {
    associatedtype Configuration: Hashable & Sendable
    associatedtype Model: LanguageModel
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    func respond(to: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto: LanguageModelExecutorGenerationChannel) async throws
}
```
Implications: (a) **streaming is the primitive** — you implement one
`respond(…streamingInto:)` that emits `Event`s (`TextFragment` w/ per-fragment
`tokenCount`, `Usage`, tool calls, reasoning) into a channel; the non-streaming
`LanguageModelSession.respond` is built on top. (b) **Capabilities are
declared, not mandatory** — `LanguageModelCapabilities` of `.vision`,
`.guidedGeneration`, `.reasoning`, `.toolCalling`; a provider advertises what
it supports (informs Q12). (c) The request carries `transcript`,
`enabledToolDefinitions`, `schema` (`GenerationSchema?`), `generationOptions`,
`contextOptions`. → The user-account Gemini/Claude providers will be
`LanguageModel`+`Executor` pairs whose executor drives the existing REST
clients (`AnthropicProvider`/`GeminiProvider`) and translates the transcript
in / fragments out.

**Feeding a runtime model (Q5 — fully answered).** Both paths take a runtime
value, so a Profile's model is **not** fixed at declaration:
- `LanguageModelSession(model: some LanguageModel, tools:, instructions:|transcript:)`
- `func model(_ model: any LanguageModel) -> some DynamicProfile` (the Dynamic
  Profile modifier). → `preferred(_ need:)` (D1) should return
  `any LanguageModel`, dropped straight into `.model(orchestrator.preferred(.reasoning))`.

**Token usage, uniform (Q10).** `LanguageModelSession.usage` →
`Usage(input:output:)` where `Input` has `totalTokenCount` + `cachedTokenCount`
and `Output` has `totalTokenCount` + `reasoningTokenCount`; streaming exposes
the same via the channel `Usage` event. This is **post-call** usage and is
uniform across models. *Caveat:* **pre-call** counting is not uniform —
`SystemLanguageModel.tokenCount(for:)` is on-device-specific, and
`PrivateCloudComputeLanguageModel.contextSize` is `async throws` (not the
synchronous `Int?` of our D13 `contextSize`). So PCC opts out of the proactive
token pre-flight and relies on the reactive `.contextWindowExceeded` (matches
D7). **Follow-up:** generalize the D13 capability surface to an async context
read so cloud/PCC models can pre-flight too.

**PCC quota + errors (Q1–Q4 — answered).**
- **Q1 (proactive?):** yes. `PrivateCloudComputeLanguageModel.quotaUsage`
  (`status: .belowLimit(isApproachingLimit:) | .limitReached`, `isLimitReached`,
  `resetDate: Date?`, `limitIncreaseSuggestion?.show()`), plus `isAvailable`
  and `availability` (`.deviceNotEligible` / `.systemNotReady`). The type is
  `Observable`.
- **Q2 (quota error type):** distinct — `PrivateCloudComputeLanguageModel.Error`
  is `.quotaLimitReached(…)` / `.serviceUnavailable(…)` / `.networkFailure(…)`.
  The generic surface also has `LanguageModelError.rateLimited(.resetDate)`.
- **Q3 (reset time):** `resetDate: Date?` on both `QuotaUsage` and the
  `.quotaLimitReached` payload → mapped to `ProviderError.rateLimited(retryAfter:)`.
- **Q4 (out-of-quota vs PCC down):** the three error cases separate them
  cleanly — `.quotaLimitReached` is the user's quota; `.serviceUnavailable` /
  `.networkFailure` are transient outages.

**PCC entitlement — the hard gate, observed at runtime (June 2026).** Tested on
an M2 Mac, macOS 27 beta. `PrivateCloudComputeLanguageModel().availability`
reported `.available` and `quotaUsage` read fine **even with no entitlement** —
but the first `respond` **traps** (a *fatal error*, not a throwable Swift
error):
```
Fatal error: Process is missing required entitlement:
com.apple.developer.private-cloud-compute
```
Consequences folded into the implementation:
- The required entitlement key is **`com.apple.developer.private-cloud-compute`**
  (answers the "which entitlement" half of Q14; the *approval* process/timeline
  is still open).
- `availability` is **not** entitlement-aware, so it cannot be the safety gate.
  Because the missing entitlement is a trap (uncatchable) and PCC is default-on,
  `PrivateCloudComputeProvider` checks the running binary's own entitlements —
  `SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement` — and reports
  `.unavailable` when the entitlement is absent, turning a guaranteed crash
  into a graceful skip.
- **Second finding (July 2026, observed live in `macOSDemo`): the gate must sit
  at CONSTRUCTION, not just at the call sites.** In a long-running unentitled
  app, merely *instantiating* `PrivateCloudComputeLanguageModel` spins up
  background status machinery (console: "Failed to check usage limit status",
  "establishment of session failed with Missing entitlement", ModelManagerError
  1007) that eventually **traps on a background thread** (`EXC_BREAKPOINT`) —
  no call-site guard can catch it because our code isn't on that stack. (The
  short-lived CLI probe survived earlier only because it exited before the
  machinery fired.) Since the entitlement is baked into the code signature and
  cannot change at runtime, the provider now decides at `init`: unentitled →
  the model is never created (`nil`) → unavailable → skipped.
- To *actually* call PCC you need a real **signed app** (not `swift run` / an
  unsigned binary) whose App ID has the PCC capability granted by Apple and
  whose `.entitlements` declares the key.

**PCC access process (Q14 — answered from Apple's docs, June 2026).** The
entitlement is **developer-side**, assigned to the *account*, not anything the
end user grants (the user only needs the normal Apple Intelligence
prerequisites; the per-user daily quota is the only user-facing dimension).
Eligibility — **all** required: enrolled in the **App Store Small Business
Program**, **< 2M** first-time App Store downloads across the account's apps,
and the entitlement assigned. Request it via Apple's form
(`developer.apple.com/contact/request/private-cloud-compute/`); Apple then
assigns it to the account. Cost: **no cloud API fee** within those limits.
Testing: PCC works via **TestFlight or ad-hoc distribution**, and test installs
do **not** count toward the 2M. If an app later crosses 2M (or leaves the
Small Business Program), Apple notifies the developer, who has 6 months to
migrate off PCC. (Q15 partial: TestFlight/ad-hoc supported; whether dev vs prod
quotas differ is still unconfirmed.)

**Transcript portability / session migration (Q6/Q7 — answered).** Sessions
are per-model: `LanguageModelSession(model:transcript:)` reconstructs a session
on *any* model from a `Transcript`, but there is **no native cross-model
KV-cache migration API**. → Confirms D12: switching provider mid-conversation
works by **replaying app-supplied history** as a transcript (exactly what
`OnDeviceProvider`/`PrivateCloudComputeProvider` do via the shared
`FoundationModelsTranscript`). KV-cache reuse is a same-model optimisation, not
a portability mechanism.

**Runtime availability API (Q11 — answered, structurally).**
`SystemLanguageModel.availability` (unchanged from 26) for on-device;
`PrivateCloudComputeLanguageModel.availability` + `isAvailable` for PCC, with
the reasons above.

**Dynamic Profiles (verified against beta 27A5237l, Aug 2026 — the Part 3
build).** Read from the same `.swiftinterface`; exercised by the demo's
`ProfileBridgeSection`.
- **Shape:** `LanguageModelSession.DynamicProfile` is SwiftUI-style —
  `associatedtype Body: DynamicProfile`, `@DynamicProfileBuilder var body`
  (single active profile per body; `buildEither` gives conditionals;
  `AnyDynamicProfile` erases). The leaf is `LanguageModelSession.Profile`,
  whose initializer takes a `@DynamicInstructionsBuilder` closure — text
  enters as `Instructions("…")` (`Instructions: DynamicInstructions`, line
  1115), and `Tool`s / `[any Tool]` can be listed in the same builder.
- **Modifiers** (all `some DynamicProfile -> some DynamicProfile`):
  `.model(any/some LanguageModel)`, `.temperature`, `.samplingMode`,
  `.maximumResponseTokens`, `.reasoningLevel`, `.toolCallingMode`,
  `.historyTransform([Transcript.Entry] -> [Transcript.Entry])`,
  `.transcriptErrorHandlingPolicy`, plus lifecycle hooks `.onPrompt`,
  `.onResponse`, `.onReasoning`, `.onToolCall`, `.onToolOutput`,
  `.onActivate`, `.onDeactivate`. A `SessionProperty` wrapper +
  `SessionPropertyValues` provide profile-scoped state.
- **Session entry:** `LanguageModelSession(profile: sending some
  DynamicProfile, history: some Collection<Transcript.Entry> = [])` — the
  `history:` slot is exactly where D12's app-supplied transcript goes.
- **Two integration findings (learned by compiling):**
  1. *Resolve-then-declare.* `preferred()` is async (availability walks);
     `.model(...)` is a synchronous modifier — so the D1 dream syntax
     `.model(orchestrator.preferred())` cannot be written inline. The
     pattern: `let model = try await orchestrator.preferred()` first, then
     declare the profile around the value. Per-call re-resolution (D7)
     survives by resolving inside the action that builds the session.
  2. *`sending` + isolation inheritance.* The session's `profile:` parameter
     is `sending`; a profile declared inside a `@MainActor` view inherits the
     actor's isolation through its instructions closure and can never be
     sent — same Swift 6 trap as the OAuth completion (July). Fix: declare
     the profile in a `nonisolated` helper so its region stays disconnected.
