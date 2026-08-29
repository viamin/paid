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

Paid previously shipped a dedicated `openrouter_free` runner key for
OpenRouter's free-tier model rotation. RDR-065 D2/D3 introduced a
`model_policy` config knob on the general-purpose `opencode` runner, issue #3673
extended the same policy shape to the other direct-outbound runners whose
provider maps already include OpenRouter (`kilocode`, `pi`, `omp`), and issue #3671
migrated every existing `openrouter_free`/`openrouter_pareto` row onto that
config shape and removed the two legacy runner keys entirely (see
`docs/rdrs/RDR-065-runner-model-selection-ux.md`). The policy values
remain `"specific"` (pin one configured model, the existing default
behavior) and `"free"` (drive selection from `tier_model_ids` via the
free-tier picker). D3 keeps `openrouter/pareto-code` a plain catalog row
rather than a third policy value.

This segment covers the `Runner` model config surface, validations, display
naming, runtime dispatch, and OpenRouter routing metadata for
`model_policy`. It also widens `FreeModels::Rotation` to recognize any
`free_model_policy?` runner whose resolved provider is OpenRouter.

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
  rows. The validations that enforce this contract
  (`tier_model_ids_must_be_valid`, `tier_models_must_be_valid`, and their
  runner-compatibility counterparts) key off `Runner#free_model_policy?`.
- A user may hold at most one free-policy runner per `(user,
  provider_api_key/integration_credential)` pair —
  `free_model_policy_runner_must_be_unique_per_credential` — since two would
  draw on the same OpenRouter free-tier quota. This is a real AR validation,
  not just a UI affordance: it blocks pairing any two free-policy runners
  (even across different runner keys, e.g. an `opencode` and a `kilocode`
  free-policy runner) on the same credential.
- Dispatch for `model_policy == "free"` is wired for the supported
  direct-outbound runners. `agent_harness_runner_runtime` resolves the
  free-tier model through `Runners::FreeModelExecutionPlan` and emits
  OpenRouter provider-routing metadata derived from the project's data
  classification. Pi and OMP additionally carry their existing
  auth metadata/env alongside the OpenRouter routing metadata. KiloCode
  translates the same routing into its provider-options config shape.
- Pi and OMP still depend on upstream CLI support to consume that
  OpenRouter provider-routing metadata: Paid can force `--provider
  openrouter` via `api_provider`, but the harness Pi/OMP providers do not
  currently interpret `metadata[:config]` for OpenRouter routing, so
  data-classification routing on those paths remains an upstream gap rather
  than an app-side omission.

### Defaults and display

- `sync_direct_outbound_tier_models` curates `tier_model_ids` from
  `FreeModels::DefaultTierModels` for any `free_model_policy?` runner.
  `clear_stale_direct_outbound_tier_models` is likewise widened so it does
  not wipe that curated mapping on unrelated saves.
- `Runner#display_name` renders `"<Runner label> Free (<API provider label>)"`
  for a free-policy direct-outbound runner (for example,
  `"OpenCode Free (OpenRouter)"`, `"Pi Free (OpenRouter)"`,
  `"Oh My Pi Free (OpenRouter)"`, `"KiloCode Free (OpenRouter)"`),
  matching the `"(API Key)"` suffix convention used elsewhere.

### Rotation parity

`FreeModels::Rotation` keys off `Runner#free_model_policy?` plus the
resolved OpenRouter provider. That parity holds for all four supported
direct-outbound runners because the service only manipulates
`tier_model_ids` and `RunnerState` metadata; provider-specific rate-limit
parsing still happens upstream in `agent_harness`, which already surfaces
`AgentHarness::RateLimitError` to the callers that decide whether to invoke
rotation. Free-policy `RunnerState` (rotation snapshots, per-model rate
limits) is keyed by the runner's routing-key `state_key`
(`"runner:<id>"`), not the bare `runner_key` string — a user may hold
several free-policy runners sharing the same `runner_key` across different
OpenRouter credentials, so `state_key` is what disambiguates them
(RDR-065, #3671).

### UI-list single-instance helper (removed)

`Runner.single_instance_runner_key?` no longer exists. It was a coarse,
credential-agnostic helper that hid an already-added key from the "Add
Runner" list, scoped only to the legacy `openrouter_free` runner key. No
current runner key is single-instance at that granularity — every API-key
runner key legitimately allows duplicates — so `RunnersController` no
longer computes or subtracts a single-instance key set
(`load_runner_options`). The real invariant, "one free-policy runner per
user per OpenRouter credential," is enforced by the AR validation above
regardless of what the "Add Runner" list shows.
