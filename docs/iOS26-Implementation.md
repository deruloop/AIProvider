# VoltaSDK — iOS 26 / 26.4 Implementation (internal source)

> Internal documentation of what is **built and shipping** (v0.3.4): the iOS 26
> base tier and the iOS 26.4 token-aware tier. For the iOS 27 design see
> `docs/iOS27-Design.md`. Keep this file in sync with every code change
> (working agreement in CLAUDE.md).

---

## 1. Verified status

Released **v0.3.4** (tags `0.1.0`–`0.3.4`, 2026-06-13). Pre-1.0 policy: 0.x while
in development; 1.0.0 is reserved for the complete feature set including the
iOS 27 extension. `swift build` succeeds and **41 tests in 8 suites pass** on
macOS 26.5 SDK / Xcode 26.6, Swift 6.2 tools. **Building requires
Xcode 26.4+** (see the toolchain-requirement note in §6); running requires
only iOS/macOS 26.0. The iOS demo app builds and
runs on the iOS 26.5 simulator (verified on iPhone 17 Pro) and signs
correctly for a physical iPhone 15 Pro Max.

File map:

```
(repo root)
├── Package.swift                          // tools 6.2, iOS 26 / macOS 26
├── README.md                              // public guide (GitHub-facing)
├── CHANGELOG.md                           // SemVer release notes
├── CLAUDE.md                              // index + state + roadmap
├── docs/                                  // internal sources (this file & co.)
├── Sources/
│   ├── VoltaSDK/                          // CORE — no UI dependency, ever
│   │   ├── ModelProvider.swift            // protocol + identifiers + statuses + typed errors (D13/D16 capabilities)
│   │   ├── ChatTurn.swift                 // app-supplied conversation turn (D12)
│   │   ├── PrivacyDisclosure.swift        // downgrade event + disclosure policy
│   │   ├── CloudVendor.swift              // vendor detection + defaults + doc links (D15)
│   │   ├── OnDeviceProvider.swift         // wraps SystemLanguageModel, maps GenerationError
│   │   ├── OpenAIProvider.swift           // Chat Completions (Codable, typed errors, SSE streaming)
│   │   ├── AnthropicProvider.swift        // Claude Messages API (x-api-key, no temperature, SSE streaming)
│   │   ├── GeminiProvider.swift           // Gemini generateContent (dual transport, SSE streaming)
│   │   ├── AIOrchestrator.swift           // orchestrator + config + fallback + resolution + streaming
│   │   ├── ServerSentEvents.swift         // shared SSE parser (D16)
│   │   ├── SessionStreaming.swift         // session snapshots → deltas for session-backed providers (D16)
│   │   ├── SessionCache.swift             // warm-session reuse for session-backed providers (D17)
│   │   ├── FoundationModelsTranscript.swift // ChatTurn ↔ native Transcript (public: the D12↔profile glue)
│   │   ├── PrivateCloudComputeProvider.swift // PCC (iOS 27, D6/D14; SecTask entitlement gate)
│   │   ├── CloudAccountLanguageModel.swift  // iOS 27 front door: vendor REST as LanguageModel+Executor
│   │   ├── LanguageModelProvider.swift    // wraps any LanguageModel into the chain (iOS 27)
│   │   ├── LanguageModelBridge.swift      // LanguageModelConvertible + preferred() conformances (D1, iOS 27)
│   │   ├── ProviderError+LanguageModel.swift // shared LanguageModelError → ProviderError mapping
│   │   └── Mocks.swift                    // MockProvider (public, for adopters' tests too)
│   ├── VoltaSDKAuth/                      // OPT-IN OAuth machinery (PKCE, Keychain, refresh) — not in core
│   ├── VoltaSDKUI/                        // OPTIONAL SwiftUI components (separate product)
│   │   ├── PrivacyLevelBadge.swift        // badge for a PrivacyLevel
│   │   ├── ProviderStatusList.swift       // fallback-chain status list (+ public Row)
│   │   ├── ModelSelector.swift            // USER-side collapsed picker + onSelection hook (+ public Row)
│   │   └── AIPlaygroundView.swift         // playground with provenance + optional PlaygroundEngine driver
│   └── VoltaSDKDemoUI/                    // demo UI shared macOS+iOS (adaptive layout)
│       ├── DemoRootView.swift             // HSplitView on macOS, TabView on iOS
│       └── ProfileEngine.swift            // iOS 27: native Dynamic Profile as the playground's 2nd driver
├── Examples/iOSDemo/                      // iPhone/iPad demo app (Xcode project)
│   ├── project.yml                        // XcodeGen spec (carries DEVELOPMENT_TEAM)
│   ├── iOSDemo.xcodeproj
│   └── Sources/iOSDemoApp.swift           // @main wrapper around DemoRootView
├── Examples/macOSDemo/                    // macOS demo app (signed Xcode project, same UI)
│   ├── project.yml
│   ├── macOSDemo.xcodeproj
│   └── Sources/macOSDemoApp.swift         // @main wrapper around DemoRootView
└── Tests/VoltaSDKTests/
    └── VoltaSDKTests.swift                // fallback, privacy, history, tokens, parsing
```

## 2. The pieces

- **`ModelProvider`** — the common protocol all providers conform to.
  Provider-agnostic so on-device, dev key, and future PCC/Gemini/Claude all fit.
  Includes the optional token capability (D13), defaulted in a protocol
  extension so custom providers compile without it.
- **`ProviderError`** — typed errors with `isRecoverableByFallback`, the hook the
  fallback logic uses. Recoverable: `.rateLimited`, `.network`,
  `.contextWindowExceeded`, `.unsupportedLanguage`, `.noProviderAvailable`.
  Terminal: `.unauthorized`, `.guardrailViolation`, `.encoding`, `.decoding`,
  `.api`, `.generation`, `.privacyRestricted`, `.cancelled`, `.emptyResponse`.
  **This is the extension point for the iOS 27 quota-driven fallback.**
- **`PrivacyLevel`** — `.external < .appleCloud < .onDevice`, comparable.
- **`PrivacyDisclosure`** — `.silent` / `.notify(handler)` /
  `.askOnPrivacyChange(asyncHandler)` / `.denyDowngrade`. Applied by the
  orchestrator whenever fallback would use a provider *below* the privacy level
  of the chain's first provider (the "baseline"). See D10.
- **`ChatTurn`** — one app-supplied conversation turn (`.user` / `.assistant`),
  the carrier of transcript transparency (D12).
- **`OnDeviceProvider`** — `SystemLanguageModel` + availability handling
  (deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady).
  Maps `LanguageModelSession.GenerationError` cases: context window →
  `.contextWindowExceeded` (recoverable), unsupported language →
  `.unsupportedLanguage` (recoverable), on-device rate limit → `.rateLimited`,
  guardrail → `.guardrailViolation` (terminal, deliberately: we never
  auto-forward content Apple blocked to an external provider).
  History is rebuilt as a native `Transcript` per call
  (`LanguageModelSession(transcript:)`).
- **`OpenAIProvider`** — Codable DTOs, HTTP status → semantic errors
  (429→rateLimited with Retry-After parsing incl. HTTP-date, 401/403→unauthorized,
  `context_length_exceeded` → `.contextWindowExceeded`). Uses
  `max_completion_tokens` (the non-deprecated parameter). History → messages
  array (system → turns → current prompt).
- **`AnthropicProvider`** — Claude Messages API (`x-api-key` +
  `anthropic-version: 2023-06-01`, top-level `system`, required `max_tokens`).
  Deliberately sends **no temperature**: Claude Opus 4.7+ rejects sampling
  parameters with a 400. 429 → rateLimited (retry-after), 5xx incl. 529
  "overloaded" → `.network` (recoverable), "prompt is too long" 400 →
  `.contextWindowExceeded`.
- **`GeminiProvider`** — Gemini `generateContent` (`x-goog-api-key`, history
  roles are user/"model", `systemInstruction` top-level). Invalid key
  surfaces as 400 "API key not valid" → mapped to `.unauthorized`.
  **Thinking models (2.5 and later, August 2026):** thinking tokens are spent
  against `maxOutputTokens`, so the SDK's 1000-token default was consumed
  entirely by thinking — a 200 OK candidate with no `content` and
  `finishReason: MAX_TOKENS`, i.e. an "empty response" (observed live with
  `gemini-3.6-flash`). Fixed on three levels: the request asks for
  `maxTokens + thinkingHeadroom(forModel:)` (4096 from 2.5 on, 0 for 1.x/2.0)
  because `maxTokens` means *tokens of answer*, and raising the ceiling costs
  nothing — the model thinks and bills either way, the cap only decides
  whether the answer survives; extraction joins ALL parts and skips
  `thought: true` summaries instead of reading `parts.first`; and a textless
  answer is diagnosed by `emptyAnswerError(finishReason:blockReason:thoughtTokens:)`
  (MAX_TOKENS → actionable `.api`, SAFETY/blocked prompt →
  `.guardrailViolation`, clean STOP → `.emptyResponse`), on the buffered and
  streamed paths alike. Response DTOs are fully optional for the same reason:
  a candidate that produced nothing carries no `content` at all, and decoding
  must survive it to report why.
- **`CloudVendor`** (D15) — which vendor a developer key belongs to:
  auto-detected from the key prefix (`sk-ant-` → Anthropic, `AIza` → Gemini,
  `sk-` → OpenAI; order matters), overridable via
  `AIConfiguration.developerKeyVendor`. Carries each vendor's default model
  and `modelDocumentationURL` (surfaced in the demo so the model field is
  never an opaque string).
- **`AIOrchestrator`** (actor) — builds the ordered provider list from
  preference; `respond`/`respondDetailed` walk the chain skipping unavailable
  providers, running the token pre-flight (D13), applying the privacy gate,
  falling through on recoverable errors. `resolveProvider()` is the
  *resolution primitive* (D9). `contextUsage()` reports window pressure;
  `providerStatuses()` powers UI. Global access via `configure {}` + `.active`
  (Mutex-protected; Swift 6 forbids bare mutable statics).

### SDK verification notes
1. ✅ `LanguageModelSession(instructions:)` exists — compiles against this SDK.
2. ✅ `LanguageModelSession.GenerationError` cases used and compiling:
   `.exceededContextWindowSize`, `.guardrailViolation`,
   `.unsupportedLanguageOrLocale`, `.rateLimited` (+ `default` for the rest).
3. ✅ `SystemLanguageModel.contextSize` is back-deployed across 26.x;
   `tokenCount(for:)` overloads require 26.4 (checked in the .swiftinterface).
4. On-device generation paths are **not** exercised by unit tests (would need a
   device with Apple Intelligence); use the demo apps for that.

## 3. The two tiers in this codebase

| Behavior | 26.0–26.3 (base) | 26.4+ (token-aware) |
|---|---|---|
| Fallback, privacy disclosure, conversations (D12) | ✅ | ✅ |
| `contextSize` (on-device) | ✅ (back-deployed) | ✅ |
| Exact on-device `tokenCount` | ❌ → `nil` | ✅ |
| Orchestrator pre-flight for on-device | inactive (no counts) | ✅ |
| `contextUsage` with on-device resolved | `nil` | ✅ |
| OpenAI estimates + window table | ✅ | ✅ |

The gate is a single `if #available(iOS 26.4, macOS 26.4, *)` inside
`OnDeviceProvider.tokenCount` — no other code branches on OS version.

## 4. Implemented design decisions (with rationale)

### D4 — Developer key = "AI included in the app's subscription"
The dev key is a business model, not a fallback hack: users with an app
subscription get AI without their own provider account. Key injected at runtime
by the integrating app (Xcode secret), never hardcoded. iOS 26: direct
URLSession call (developer's key in device traffic; consider a proxy at scale).

### D5 — On-device is never assumed present
Requires Apple Intelligence. Detected at runtime; unavailable options are
hidden; never assumed as a guaranteed last resort.

### D7 — Runtime fallback + privacy levels + disclosure
State changes while the user uses the app, so model choice is re-evaluated per
call. Behind the preference is an ordered chain walked at runtime. Crossing the
privacy threshold triggers a configurable disclosure. Only the developer knows
their app's sensitivity, so they choose the policy. (The iOS 27 per-need chain
extends this — see `docs/iOS27-Design.md`.)

### D8 — The orchestrator type is `AIOrchestrator`, not `VoltaSDK`
A type named like its own module shadows the module: `VoltaSDK.Xyz` would
always resolve the type, never the module — a permanent ergonomic tax on every
client. Renamed before anyone adopted the API. The name also says what the
thing is: an orchestrator/resolver, not an agent runtime.

### D9 — Resolution is the primitive; `respond` is the convenience
`respond()` executes; but our core value is *resolution*. So the resolution
primitive is public from day one: `resolveProvider()` returns the chain's first
usable provider without executing anything. On iOS 27 it evolves into
`preferred(_ need:) -> LanguageModel` for Dynamic Profiles — "the primitive
existed all along". `respond`/`respondDetailed` stay as the one-shot
convenience (and `respondDetailed` reports *which* provider answered, at what
privacy level — needed by any honest UI).

### D10 — Privacy disclosure ships in iOS 26, not iOS 27
With `.preferOnDevice`, a transient on-device failure silently re-sends the
user's prompt to OpenAI — a privacy downgrade that happens **today**. So the
disclosure mechanism is live in the base: the baseline is the privacy level of
the chain's *first* provider; before using any provider below it, the
orchestrator applies `PrivacyDisclosure`. Consequence: `.contextWindowExceeded`
and `.unsupportedLanguage` can safely be *recoverable* errors, because the
privacy policy — not the error taxonomy — decides whether crossing to an
external provider is acceptable. Guardrail violations remain terminal by
deliberate choice (never auto-forward content Apple blocked).

### D11 — UI is optional by construction
The core target has zero UI dependencies and is fully configurable headless;
the developer can build any UI on `providerStatuses()` / `respondDetailed()`.
`VoltaSDKUI` is a **separate library product** with drop-in, customizable
SwiftUI components (`PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
`AIPlaygroundView`). Rows/badges are public so developers can recompose them.
Nothing in the core ever imports SwiftUI.

### D12 — Stateless core, transcript-transparent
The framework **never remembers** conversations, but every call **accepts**
the prior turns as input (`history: [ChatTurn]`, owned and supplied by the
app). Three reasons:
1. **Ownership.** Persistence, editing, trimming, branching of a chat are app
   domain logic. A framework-held session would be an agent runtime,
   and would duplicate Apple's `LanguageModelSession`.
2. **Fallback composability — the key insight.** If conversation state lived
   inside a provider's session, a mid-conversation provider death (PCC quota
   exhausted, on-device rate limit) would trap the transcript in the dead
   provider. With app-supplied history, **every call is self-contained**, so
   any provider in the chain can answer any turn: mid-conversation provider
   switching falls out of the existing per-call fallback for free, privacy
   disclosure included.
3. **Provider mapping is natural.** OpenAI: history → messages array.
   On-device: history → native FoundationModels `Transcript` rebuilt per call.
Known costs, accepted: history is re-sent (and re-prefilled) each turn — no
KV-cache reuse; and long chats hit the small on-device window sooner, which the
architecture absorbs (`.contextWindowExceeded` is recoverable → falls over to a
larger-context provider, privacy policy permitting). When/how to trim or
summarize stays with the developer. `AIPlaygroundView` demonstrates the
pattern: the *view* plays the developer role, holds the exchanges, and passes
them via `history:` on each send.

### D13 — Proactive token awareness as an optional capability
Verified against the real SDK: `SystemLanguageModel.contextSize` is available
on **all of 26.x** (back-deployed), while the five `tokenCount(for:)` overloads
(prompt, instructions, tools, schema, transcript entries) require **26.4**.
Design:
- `ModelProvider` gains an *optional capability* (defaulted in a protocol
  extension): `contextSize: Int?` and
  `tokenCount(prompt:instructions:history:) -> Int?`. `nil` always means
  "don't know" — the framework never guesses.
- On-device: exact counts via the native Transcript entries on 26.4+, `nil` on
  26.0–26.3. OpenAI: known windows per model family (`nil` for unknown models,
  overridable in init) + an ~4 chars/token estimate, deliberately on the low
  side: pre-flight must never wrongly skip a usable provider; real overflow is
  still caught reactively.
- Orchestrator **pre-flight**: if a provider can count and
  `needed + responseTokenReserve >= window`, it's skipped as if it had thrown
  `.contextWindowExceeded` — same recoverable semantics and privacy gating,
  without paying for a doomed generation. Runs *before* the privacy gate (never
  ask the user about a provider that can't serve the call). The reserve is
  `config.maxTokens` (or explicit in `init(providers:)`).
- `contextUsage(instructions:history:)` reports the conversation's pressure on
  the *resolved* provider's window. The app decides when to trim/summarize —
  same division of labor as D10/D12: we detect, the developer decides.
- This capability surface is where iOS 27's per-model token reading will land.

### D15 — The developer key is vendor-agnostic
One configuration slot (`developerKey`) accepts OpenAI, Anthropic (Claude),
or Google (Gemini) keys. The vendor is auto-detected from the key format and
overridable (`developerKeyVendor`); the model name travels WITH the key
(`developerKeyModel`, `nil` = vendor default) because a model string only
makes sense for the vendor that issued the key. Rationale: D4 frames the dev
key as "AI included in the app's subscription" — which vendor backs it is the
developer's business decision, and the framework shouldn't privilege one.
Implementation notes: Anthropic sends no `temperature` (Opus 4.7+ 400s on
sampling params); **vendor defaults are perishable** — Google retired
`gemini-2.5-flash` for new accounts in August 2026 ("no longer available to
new users"), so `CloudVendor.defaultModel` moved to `gemini-3.6-flash`; every
vendor has list-models endpoints (OpenAI/Anthropic
`GET /v1/models`, Gemini `ListModels`) — fetching them to populate a model
picker is a roadmap item, not yet built.

### D16 — Streaming as an optional capability, fallback until the first fragment
`streamResponse` on `ModelProvider` is an optional capability in the D13
idiom: the protocol default buffers `respond` and delivers the whole answer
as ONE fragment, so every provider — including adopters' custom ones — can
take part in a streamed chain without code changes; providers with a native
path override it with real token deltas. All five built-ins override it:
OpenAI/Anthropic/Gemini via SSE (`"stream": true`; Gemini's
`streamGenerateContent?alt=sse` on the Developer API transport only — the
Code Assist OAuth envelope stays buffered), on-device/PCC/`LanguageModelProvider`
via the session's native `streamResponse` with cumulative snapshots converted
to deltas (`SessionStreaming`). The orchestrator's `streamResponse` /
`streamDetailed` run the same chain walk as `respond` (availability,
pre-flight, privacy gate), with one rule: **automatic fallback applies only
until the first fragment reaches the caller** — after any text is visible, a
failure surfaces as an error. Rationale: silently re-answering with a
different model would retract text the user already read; a pre-first-token
failure is indistinguishable from the buffered case, so the chain still steps
down silently there. Privacy disclosure keeps firing BEFORE any data is sent,
never mid-stream. Fragments are deltas (concatenation = full answer);
`.began(provider:privacyLevel:)` precedes the first fragment as the streamed
counterpart of `AIResponse` provenance. Mid-stream vendor errors map like
HTTP ones (Anthropic `overloaded_error` → transient network, `rate_limit_error`
→ `.rateLimited`); on iOS 27 the `CloudAccountLanguageModel` executor forwards
the same fragments into Apple's generation channel, closing the
"single-fragment executor" gap from session 339.

### D18 — Privacy downgrades are logged by default, not silent
`PrivacyDisclosure` gains a `.log` case — the downgrade is recorded to the
unified log (subsystem "VoltaSDK", category "privacy") — and it replaces
`.silent` as the default everywhere. Rationale (self-criticism, Sep 2026): a
privacy-first SDK whose default lets a journal entry silently fall through to
an external vendor was the wrong default; logging reaches no end user,
requires no handler, costs nothing, and makes the fallback visible in
Console/Instruments during development. `.silent` remains available as an
explicit opt-in. Behavior change within 0.x (allowed pre-1.0).

### D17 — Warm-session reuse: verify the continuation, never assume it
Rebuilding a session per call (the D12 discipline) re-processes the whole
conversation prefix on every turn — a growing time-to-first-token tax on the
session-backed providers (on-device, PCC, wrapped `LanguageModel`s; REST
providers are untouched — HTTP chat APIs re-send history for everyone, so
there is nothing to reuse). D17 removes the tax without touching D12's
semantics: each session-backed provider holds a `SessionCache` with ONE warm
session plus the exact conversation it has absorbed (instructions + history
+ every exchange completed since). A call reuses the warm session **iff its
(instructions, history) equals that conversation exactly** — then only the
new prompt is processed, matching a natively held Apple session. Any
divergence (the app trimmed/edited history, new conversation, different
instructions) is a miss: discard, rebuild from the app's history — the
pre-D17 behaviour. The app still owns the history; the cache *verifies*
continuation rather than assuming it, which is what keeps D12 honest.
Bookkeeping: check-in only after a SUCCESSFUL, non-empty turn (an errored or
mid-stream-failed session may hold an inconsistent transcript and is
dropped); `checkOut` removes the entry, so concurrent calls can never share
a session (the race loser builds fresh); a config change rebuilds providers
→ cold caches. Scope: one session per provider — alternating between two
conversations misses every time (no regression, just no benefit).

## 5. Public API that must stay stable

```swift
// configuration
AIOrchestrator.configure { (config: inout AIConfiguration) in ... }
AIOrchestrator(configuration: AIConfiguration)      // explicit, no global state
AIOrchestrator(providers: [any ModelProvider],      // tests / custom providers
               privacyDisclosure: PrivacyDisclosure,
               responseTokenReserve: Int)
AIOrchestrator.active                               // configured shared instance

// usage — history is app-owned conversation context (D12), defaults to [];
// every entry point also takes `need: ModelNeed? = nil` (D7): a per-call
// hint (.lightweight / .reasoning / .largeContext) that REORDERS the chain
// for that call (tiers by privacy level; .largeContext sorts within-tier by
// known window size and stays reactive — the D13 pre-flight does the routing)
try await kit.respond(to: prompt, instructions: nil, history: [], need: nil) -> String
try await kit.respondDetailed(to:instructions:history:need:) -> AIResponse  // + provenance
await kit.streamResponse(to:instructions:history:need:) -> AsyncThrowingStream<String, Error>       // (D16)
await kit.streamDetailed(to:instructions:history:need:) -> AsyncThrowingStream<AIStreamEvent, Error> // + provenance
try await kit.resolveProvider(for: need) -> any ModelProvider   // the primitive (D9)
try await kit.preferred(_ need: ModelNeed? = nil) -> any LanguageModel  // iOS 27: Dynamic Profiles bridge (D1/D7)
enum ModelNeed { lightweight, reasoning, largeContext }         // (D7)
FoundationModelsTranscript.entries(instructions:history:) -> [Transcript.Entry]  // ChatTurn → native transcript (D12↔profile glue)
struct PlaygroundEngine { label, footnote, stream }  // VoltaSDKUI: app-supplied playground driver (D1)
await kit.contextUsage(instructions:history:) -> ContextUsage?  // window pressure (D13)
await kit.availableProviders() -> [ProviderIdentifier]
await kit.providerStatuses() -> [ProviderStatus]                // for UI

// extension points
protocol ModelProvider { identifier; privacyLevel; availability(); respond(to:instructions:history:);
                         streamResponse(to:instructions:history:);               // defaulted: one fragment (D16)
                         contextSize; tokenCount(prompt:instructions:history:) }  // last two defaulted (D13)
enum AIStreamEvent { began(provider:privacyLevel:), text(String) }               // (D16)
enum ProviderError { ...; var isRecoverableByFallback: Bool }
enum PrivacyLevel { external < appleCloud < onDevice }
enum PrivacyDisclosure { silent, log /* default, D18 */, notify(…), askOnPrivacyChange(…), denyDowngrade }
struct PrivacyDowngrade { from, to, provider }
enum ModelPreference { preferOnDevice, preferDeveloperKey, onDeviceOnly, developerKeyOnly }
enum CloudVendor { openAI, anthropic, gemini; detect(fromKey:); defaultModel; modelDocumentationURL } // (D15)
struct ChatTurn { role (.user/.assistant), text }               // app-supplied turn (D12)
struct AIResponse { text, provider, privacyLevel }
struct ProviderStatus { identifier, privacyLevel, availability, contextSize }
struct ContextUsage { tokens, contextSize, provider, fraction } // (D13)
```

Adding iOS 27 providers/quota/Dynamic-Profiles bridge must extend these, not
break them (SemVer: iOS 27 stays in 1.x). `VoltaSDKUI` components are
additive and optional by definition.

### ModelSelector contract (VoltaSDKUI)

- Collapsed-by-default disclosure: resting footprint is one row regardless of
  provider count. External commits (setting the `selection` binding) collapse
  and refresh it.
- **Gate invariant (June 2026 fix):** nothing is ever committed without
  passing through `onSelection` — including the selector's own initial
  state. With a nil binding it auto-selects on-device iff available (the
  only gate-free provider: free, private, no account), running even that
  through the handler; `.deny`/`.deferred` leave it unselected with no
  failure message (not a user action). Cloud providers are **never
  preselected** — a developer preference must not masquerade as a user
  activation when a subscription/OAuth gate sits behind it. A non-nil
  initial binding (persisted user choice) is never overridden.
  `selection == nil` means "no model committed": the app must gate its chat
  on it or keep gated providers out of the config — the selector cannot
  stop the orchestrator from resolving them.
- `onSelection: (ProviderIdentifier) async -> ModelSelectionResponse` with
  `.activate` / `.deny(message:)` / `.deferred`. `.deferred` is the
  extensibility point: the app presents its own view (paywall, settings,
  iOS 27 OAuth page) and commits later via the binding. The selector never
  owns business logic; it reacts.
- Default labels are neutral on purpose: no "included with subscription"
  claims — the developer brands rows via `labels:`.

### How apps express roles/personas today (pre-Dynamic Profiles)

There is deliberately no `Agent` type (D2). A "role" today is a value the
app owns: **instructions + its own history + optionally a preferred
provider**. Because the core is stateless and transcript-transparent (D12),
an app can run any number of personas in parallel — each is just a different
`instructions` string and a separate `[ChatTurn]` array passed per call
(`respond(to:instructions:history:)`). On-device, instructions become the
session/Transcript `Instructions` entry; on cloud vendors they become the
system message. On iOS 27, Dynamic Profiles replace the app-side struct:
instructions/tools move into Apple's declarative `DynamicProfile`, and Volta's
contribution narrows to `.model(orchestrator.preferred(.reasoning))` — which
is why we never built a role abstraction that would now be in the way.

## 6. Demo & verification

- `swift build` — builds core + UI + demo (macOS side).
- `swift test` — 41 tests: fallback chain, terminal vs recoverable errors,
  vendor detection and provider construction (D15),
  privacy disclosure policies (all four), resolution primitive, provider
  statuses, conversation-history pass-through incl. across fallback (D12),
  token pre-flight incl. response reserve and the no-capability case (D13),
  context-usage reporting, OpenAI window table + estimate,
  global configure, Retry-After parsing.
- **macOS demo:** open `Examples/macOSDemo/macOSDemo.xcodeproj` and run.
- **iOS demo:** open `Examples/iOSDemo/iOSDemo.xcodeproj` and run on an
  iPhone/iPad (or simulator with an iOS 26 runtime — Xcode 26.6 ships iPhone 17
  family simulators). The project was generated with XcodeGen from
  `project.yml`; it's committed, so regenerate (`xcodegen generate`) only after
  editing the spec. The development team is set in `project.yml`
  (`DEVELOPMENT_TEAM`), so it survives regeneration — don't set it only in
  Xcode's Signing pane, that edit lives in the generated pbxproj.

Both demos render the same `DemoRootView` (target `VoltaSDKDemoUI`), split
into the two roles of a real integration. Layout is adaptive — split view on
macOS (developer | user), tabs (Developer / User) on iOS.
- **Developer side:** providers/key/default-preference form, privacy policy,
  a simulated subscription entitlement toggle, "Apply configuration", and the
  fallback-chain status with real availability reasons and window sizes.
  The key field accepts any vendor's key and shows the detected vendor; the
  model field is deliberately NOT pre-filled (the name belongs to the key's
  vendor), shows the vendor's default as a placeholder, and a disclosure
  links to each vendor's model documentation (D15). Keyboard dismisses
  interactively by scrolling everywhere (form and chat).
- **User side:** the chat on top, the `ModelSelector` below. The chat is
  **disabled until a model is committed** (the `selection == nil` contract:
  without the gate, a fallback preference would let the cloud provider
  answer before ever passing the activation gate). With on-device available
  the selector auto-commits it through the handler, so the chat starts
  enabled; without it, the user must pick — and the cloud option goes
  through the entitlement gate. The selector is
  **collapsed by default** (a single row with the active choice + chevron;
  expanding shows the options — scales to iOS 27's longer provider list).
  The user's selection re-leads the chain (selection → preference mapping in
  `DemoRootView.effectivePreference`). Tapping an option runs the demo's
  `onSelection` handler: on-device → `.activate`; cloud model → entitlement
  check, then `.activate` if the simulated subscription is on, otherwise
  `.deferred` + a paywall sheet — the app-owned custom flow that later
  commits by setting the `selection` binding (exactly how an iOS 27 OAuth
  page will work). The collapsed row doubles as the "active" confirmation.
The playground is a real conversation (D12): follow-ups work because the view
holds the history and passes it per call; "New conversation" resets it. It
also shows the context pressure ("context N% of \<window\>", orange above
80%) for the provider that would answer next. On 26.0–26.3 the on-device
pressure indicator simply doesn't appear (no counting API): that's the base
tier behaving as designed. Conversations survive an orchestrator rebuild
(configuration or selector change) — the history lives in the view, another
D12 consequence.

Model-limitation behavior to expect:
- Simulator / non-Apple-Intelligence device: on-device row shows the reason
  (e.g. "Apple Intelligence is not enabled in Settings") and the chain
  falls back to the developer key if configured — with the privacy-downgrade
  notification visible in the Privacy section.
- iPhone 15 Pro / 16+ with Apple Intelligence on: on-device row is green and
  answers carry the "On device" badge.
- Context-window overflow / unsupported language on-device fall through to the
  cloud provider per D10; guardrail violations surface as errors (terminal).

**Toolchain requirement (learned June 2026, from an adopter's CI failure):**
the package **builds only with Xcode 26.4+** (the 26.4 SDK).
`OnDeviceProvider.tokenCount` references
`SystemLanguageModel.tokenCount(for:)`, declared only from the 26.4 SDK —
the `#available(iOS 26.4, …)` gate is a *runtime* check and does not remove
the compile-time dependency on the declaration. Symptom: a CI runner pinned
to Xcode 26.0.x fails to compile VoltaSDK while local builds on a newer
Xcode pass. Fix: update the runner. Deliberately NOT worked around with
compile-time conditionals: building with an old toolchain would silently
strip the token-aware tier for every user regardless of their OS, breaking
D14's promise that capabilities depend on the device at runtime, not the
build environment (and `#if compiler` can't distinguish the toolchains
anyway — Xcode 26.0 and 26.6 both report Swift 6.2 tools).

**Device-install troubleshooting (learned June 2026):** Xcode's
"Install Application not available (DVTCoreDevice code 4)" can mean the
*phone* doesn't expose the `com.apple.coredevice.feature.installapp`
capability — i.e. app installation is blocked on the device (typically
Screen Time → Content & Privacy Restrictions → Installing Apps = Don't Allow,
or an MDM profile), even with Developer Mode on and pairing fine. Diagnose with
`xcrun devicectl device install app --device <id> <app>` (real error) and
`xcrun devicectl device info details --device <id>` (capability list,
developerModeStatus).

## 7. Origin

Started from a primitive `ChatGptManager` (single OpenAI REST class returning
`String?`). Its best ideas — the repository protocol and the mock — were
generalized into `ModelProvider` and `MockProvider`. The rest was rebuilt
around typed errors, config, the orchestrator, and (June 2026) the resolution
primitive, privacy disclosure, transcript transparency, and token awareness.
