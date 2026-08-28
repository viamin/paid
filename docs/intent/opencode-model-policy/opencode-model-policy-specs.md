# EARS Specs: Direct-Outbound Free Model Policy Configuration

> Testable claims for the `model_policy` config knob on the direct-outbound
> runners that can route through OpenRouter (`opencode`, `kilocode`, `pi`,
> `omp`). Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r MODEL-POLICY-001`).

## Config and Validation

- [x] **MODEL-POLICY-001** — When an `opencode` runner's config omits
  `model_policy`, `Runner#opencode_model_policy` SHALL default to
  `"specific"`. For any other `runner_key`, it SHALL return `nil`. A
  `model_policy` value outside `Runner::MODEL_POLICIES` SHALL fail
  validation with an error on `:config`.
- [x] **MODEL-POLICY-002** — When a direct-outbound runner in
  `opencode`, `kilocode`, `pi`, or `omp` sets `model_policy: "free"`, the
  system SHALL require its derived API provider to be `"openrouter"` and
  SHALL NOT require the runner-specific model id to be present.
- [x] **MODEL-POLICY-003** — When a direct-outbound runner's `model_policy`
  is `"specific"` (explicit or defaulted), the system SHALL preserve each
  runner's prior model-id contract: `opencode` and `kilocode` continue to
  require a configured model id, while `pi` and `omp` continue to allow a
  blank model and defer to the provider default.
- [x] **MODEL-POLICY-004** — `Runner#free_model_policy?` SHALL be true for
  the legacy `openrouter_free` runner key and for any `opencode`,
  `kilocode`, `pi`, or `omp` runner with `model_policy == "free"`. The
  `tier_model_ids`/`tier_models` validations that require free-pricing
  `LlmModel` rows, and their runner-compatibility counterparts that skip the
  generic compatibility check, SHALL key off this predicate rather than the
  `openrouter_free` runner key alone.
- [x] **MODEL-POLICY-011** — When a free-policy direct-outbound runner in
  `opencode`, `kilocode`, `pi`, or `omp` is enabled for agent runs,
  fallback, or chat, the system SHALL dispatch it through an OpenRouter-aware
  runtime that carries the runner's OpenRouter credential plus
  data-classification routing metadata equivalent to the legacy
  `openrouter_free` runner. Pi/OMP/KiloCode SHALL preserve their
  runner-specific runtime metadata/env shape while adding that routing data.

## Defaults and Display

- [x] **MODEL-POLICY-005** — When a `free_model_policy?` runner (legacy or
  config-driven) saves with blank `tier_model_ids`, `sync_direct_outbound_tier_models`
  SHALL curate them from `FreeModels::DefaultTierModels`, and
  `clear_stale_direct_outbound_tier_models` SHALL NOT clear an already-curated
  mapping on unrelated attribute saves.
- [x] **MODEL-POLICY-006** — `Runner#display_name` for a free-policy
  direct-outbound runner without an explicit `name` SHALL render
  `"<Runner label> Free (<API provider label>)"` (for example,
  `"OpenCode Free (OpenRouter)"`), with the existing `" (API Key)"` suffix
  for api_key auth. The legacy `openrouter_free` display path is unchanged.

## Uniqueness and Params

- [x] **MODEL-POLICY-007** — A user SHALL NOT hold two free-policy runners
  (legacy `openrouter_free` or `opencode` with `model_policy: "free"`)
  against the same `provider_api_key`/`integration_credential`, since both
  would draw on the same OpenRouter free-tier quota. Free-policy runners on
  distinct credentials, and non-free-policy `opencode` runners on the same
  credential as a free-policy runner, remain allowed.
- [x] **MODEL-POLICY-008** — `RunnersController#runner_params` SHALL permit
  `model_policy` under the `opencode` config block so the free policy can be
  set through the runner create/update form.

## Deferred

- [x] **MODEL-POLICY-009** — Runtime dispatch
  (`agent_harness_runner_runtime`/`requires_direct_outbound?`) and free-model
  rotation (`FreeModels::Rotation`) SHALL recognize `model_policy == "free"`
  on `opencode`, `kilocode`, `pi`, and `omp` runners the same way they
  recognize the legacy `openrouter_free` runner key.
- [D] **MODEL-POLICY-010** — Re-scoping `Runner.single_instance_runner_key?`
  (the "Add Runner" UI-list helper) from a bare runner-key check onto the
  `free_model_policy?` config predicate. Deferred to the
  `openrouter_free` -> `opencode` migration issue; the real uniqueness
  invariant is enforced today by MODEL-POLICY-007 regardless of what the
  "Add Runner" list shows.
