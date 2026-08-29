---
parent: PAID
prefix: MODEL-POLICY
---

# Low-Level Design: Direct-Outbound Free Model Policy Configuration

> Companion to the high-level design (`docs/high-level-design.md`). Tracks
> GitHub issue #3668 (RDR-065, 4/8), widened by follow-up issue #3673 after
> #3663/#3672 closeout. This segment covers the `model_policy` config for the
> direct-outbound runners that can route through OpenRouter (`opencode`,
> `kilocode`, `pi`, `omp`).

## Context

Paid ships a dedicated `openrouter_free` runner key for OpenRouter's
free-tier model rotation. RDR-065 D2/D3 introduced a `model_policy` config
knob on the general-purpose `opencode` runner, and issue #3673 extends the
same policy shape to the other direct-outbound runners whose provider maps
already include OpenRouter: `kilocode`, `pi`, and `omp`. The policy values
remain `"specific"` (pin one configured model, the existing default
behavior) and `"free"` (drive selection from `tier_model_ids` via the
free-tier picker, mirroring `openrouter_free`). D3 keeps
`openrouter/pareto-code` a plain catalog row rather than a third policy
value.

This segment covers the `Runner` model config surface, validations, display
naming, runtime dispatch, OpenRouter routing metadata, and free-model
rotation for `model_policy`. A direct-outbound runner with
`model_policy == "free"` now executes through the same OpenRouter free-model
execution plan and rotation flow as the legacy `openrouter_free` runner,
keyed by the runner's routing identifier so policy-based rows preserve their
own recovery state independent of other free-policy runners. It also widens
`FreeModels::Rotation` to recognize any `free_model_policy?` runner whose
resolved provider is OpenRouter. The legacy `openrouter_free` runner key and
its dedicated form section (`free-model-runner-config`) remain fully
functional pending a later migration issue that moves existing rows onto the
new config shape.

## Design

### `model_policy` config

`runners.config[<runner_key>]["model_policy"]` accepts `"specific"` (default,
may be omitted) or `"free"` for the direct-outbound runner keys
`opencode`, `kilocode`, `pi`, and `omp`. Runner accessors expose
`#opencode_model_policy`; the follow-up broadening uses the same config key
for the other runners and keys the shared predicate off the stored value plus
the runner key/provider.

```ruby
{ "opencode" => { "model" => "...", "model_policy" => "specific" } }  # default
{ "opencode" => { "model_policy" => "free" } }                         # tier picker drives tier_model_ids
{ "pi" => { "model_policy" => "free" } }
{ "omp" => { "model_policy" => "free" } }
{ "kilocode" => { "model_policy" => "free" } }
```

### Validation

- `model_policy` must be one of `Runner::MODEL_POLICIES` (`specific`,
  `free`).
- `free` is valid only when the runner's derived API provider is
  `openrouter`.
- `specific` (the default) still requires the runner-specific configured
  model id for `opencode` and `kilocode`, unchanged from prior behavior.
  `pi` and `omp` keep their existing optional model field in specific mode,
  so a blank model continues to defer to the provider default.
- `free` requires `tier_model_ids` to resolve exclusively to free `LlmModel`
  rows, the same contract already enforced for `openrouter_free`.
  `Runner#free_model_policy?` unifies both the legacy runner-key check and
  the new config predicate so the validations that enforce this contract
  (`tier_model_ids_must_be_valid`, `tier_models_must_be_valid`, and their
  runner-compatibility counterparts) cover both shapes identically.
- A user may hold at most one free-policy runner (legacy or config-driven)
  per `(user, provider_api_key/integration_credential)` pair —
  `free_model_policy_runner_must_be_unique_per_credential` — since two would
  draw on the same OpenRouter free-tier quota. This is a real AR validation,
  not just a UI affordance: it also blocks pairing a legacy `openrouter_free`
  runner with an `opencode` free-policy runner on the same credential.
- A free-policy runner (any of `opencode`, `kilocode`, `pi`, `omp`) may be
  enabled for agent runs and fallback once it passes the same free-model
  validations as the legacy `openrouter_free` runner. Dispatch for
  `model_policy == "free"` is wired for all four: `agent_harness_runner_runtime`
  resolves the tier model and builds the OpenRouter runtime through
  `Runners::FreeModelExecutionPlan`, so the request carries the same base
  URL, API-key env binding, and `OpenRouterDataRouting` metadata as the
  legacy runner. Pi and OMP additionally carry their existing auth
  metadata/env alongside the OpenRouter routing metadata. KiloCode
  translates the same routing into its provider-options config shape.
- Pi and OMP still depend on upstream CLI support to consume that
  OpenRouter provider-routing metadata: Paid can force `--provider
  openrouter` via `api_provider`, but the harness Pi/OMP providers do not
  currently interpret `metadata[:config]` for OpenRouter routing, so
  data-classification routing on those paths remains an upstream gap rather
  than an app-side omission.
- Chat is different: chat dispatch (`ChatSessions::BuildLlmClient`,
  `Containers::ChatSessionManager`) does not yet resolve a free-tier model
  for policy-based free runners — only the legacy `openrouter_free` runner
  has that support today. `Runner#opencode_free_policy_chat_must_be_disabled`
  rejects `enabled_for_chat: true` on any free-policy `opencode` runner
  (create, update, or a row written outside `RunnersController`), so it
  cannot end up chat-enabled and silently fall through to a paid default
  model. `RunnersController#apply_new_runner_defaults` additionally defaults
  `enabled_for_chat` to `false` on create as a UX convenience, but the model
  validation is what actually enforces the gate. This will be relaxed once
  chat-side free-model resolution lands for policy-based free runners.
  (`MODEL-POLICY-011`)

### Defaults and display

- `sync_direct_outbound_tier_models` curates `tier_model_ids` from
  `FreeModels::DefaultTierModels` for any `free_model_policy?` runner
  (legacy or config-driven), matching the existing `openrouter_free` default
  behavior. `clear_stale_direct_outbound_tier_models` is likewise widened so
  it does not wipe that curated mapping on unrelated saves.
- `Runner#display_name` renders `"<Runner label> Free (<API provider label>)"`
  for a free-policy direct-outbound runner (for example,
  `"OpenCode Free (OpenRouter)"`, `"Pi Free (OpenRouter)"`,
  `"Oh My Pi Free (OpenRouter)"`, `"KiloCode Free (OpenRouter)"`),
  matching the `"(API Key)"` suffix convention used elsewhere.
  `display_name_for` (the class-level, config-blind variant) and the legacy
  `openrouter_free` display path are unchanged.

### Rotation parity

`FreeModels::Rotation` now keys off `Runner#free_model_policy?` instead of
the legacy `openrouter_free` runner key alone — the free-policy validations
(`direct_outbound_model_policy_must_be_valid`) already guarantee the
resolved provider is OpenRouter for any `free_model_policy?` runner, so a
separate provider check at the rotation layer would be redundant. `RunnerState`
rows are looked up and written through `Runner#free_model_rotation_state_key`
(the bare `"openrouter_free"` key for legacy rows, the routing key for
policy-based free runners) so multiple free-policy runners on distinct
credentials keep independent recovery state. That parity is safe for all
four supported direct-outbound runners because the service only manipulates
`tier_model_ids` and `RunnerState` metadata; provider-specific rate-limit
parsing still happens upstream in `agent_harness`, which already surfaces
`AgentHarness::RateLimitError` to the callers that decide whether to invoke
rotation.

### UI-list single-instance helper (deferred)

`Runner.single_instance_runner_key?(runner_key)` — the coarse,
credential-agnostic helper that hides an already-added key from the "Add
Runner" list — stays scoped to the legacy `openrouter_free` runner key only.
It cannot express the finer-grained "one free-policy runner per credential"
rule from a bare runner_key string (opencode legitimately allows many
runners with different credentials). Re-scoping that UI helper onto the same
config predicate is deferred to the openrouter_free -> opencode migration
issue; the real invariant is enforced today by the AR validation above
regardless of what the "Add Runner" list shows.
