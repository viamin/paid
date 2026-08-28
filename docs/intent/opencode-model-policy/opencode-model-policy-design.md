---
parent: PAID
prefix: MODEL-POLICY
---

# Low-Level Design: OpenCode Model Policy Configuration

> Companion to the high-level design (`docs/high-level-design.md`). Tracks
> GitHub issue #3668 (RDR-065, 4/8), implementing decisions D2/D3 from #3663.
> A prerequisite for issues 5/8 and 6/8, which wire the free policy into
> runtime dispatch and free-model rotation respectively.

## Context

Paid ships a dedicated `openrouter_free` runner key for OpenRouter's
free-tier model rotation. RDR-065 D2/D3 replace that special-cased runner key
with a `model_policy` config knob on the general-purpose `opencode` runner:
`"specific"` (pin one configured model, the existing default behavior) or
`"free"` (drive selection from `tier_model_ids` via the free-tier picker,
mirroring `openrouter_free`). D3 keeps `openrouter/pareto-code` a plain
catalog row rather than a third policy value — Pareto routing is not modeled
here.

This segment covers the `Runner` model config surface, validations, display
naming, runtime dispatch, and free-model rotation for `model_policy`. An
`opencode` runner with `model_policy == "free"` now executes through the same
OpenRouter free-model execution plan and rotation flow as the legacy
`openrouter_free` runner, keyed by the runner's routing identifier so
policy-based rows preserve their own recovery state. The legacy
`openrouter_free` runner key and its dedicated form section
(`free-model-runner-config`) remain fully functional pending the later
migration issue that moves existing rows onto the new config shape.

## Design

### `model_policy` config

`runners.config["opencode"]["model_policy"]` accepts `"specific"` (default,
may be omitted) or `"free"`. `Runner#opencode_model_policy` reads it, nil for
any other `runner_key`.

```ruby
{ "opencode" => { "model" => "...", "model_policy" => "specific" } }  # default
{ "opencode" => { "model_policy" => "free" } }                         # tier picker drives tier_model_ids
```

### Validation

- `model_policy` must be one of `Runner::MODEL_POLICIES` (`specific`,
  `free`).
- `free` is gated to the `opencode` runner key with the `openrouter` API
  provider (phase-1; Pi/OMP/KiloCode free policies are a follow-up issue).
- `specific` (the default) still requires `opencode_model_id`, unchanged from
  prior behavior.
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
- A free-policy `opencode` runner may be enabled for agent runs and fallback
  once it passes the same free-model validations as the legacy
  `openrouter_free` runner. Runtime dispatch resolves its tier model and
  builds the OpenRouter runtime through `Runners::FreeModelExecutionPlan`,
  so the request carries the same base URL, API-key env binding, and
  `OpenRouterDataRouting` metadata as the legacy runner.
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
- `Runner#display_name` renders `"OpenCode Free (<API provider label>)"` for
  a free-policy `opencode` runner (e.g. `"OpenCode Free (OpenRouter)"`),
  matching the `"(API Key)"` suffix convention used elsewhere.
  `display_name_for` (the class-level, config-blind variant) and the legacy
  `openrouter_free` display path are unchanged.

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
