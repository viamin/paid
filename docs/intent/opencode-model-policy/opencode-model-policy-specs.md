# EARS Specs: OpenCode Model Policy Configuration

> Testable claims for the `model_policy` config knob on the `opencode`
> runner. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r MODEL-POLICY-001`).

## Config and Validation

- [x] **MODEL-POLICY-001** — When an `opencode` runner's config omits
  `model_policy`, `Runner#opencode_model_policy` SHALL default to
  `"specific"`. For any other `runner_key`, it SHALL return `nil`. A
  `model_policy` value outside `Runner::MODEL_POLICIES` SHALL fail
  validation with an error on `:config`.
- [x] **MODEL-POLICY-002** — When an `opencode` runner sets
  `model_policy: "free"`, the system SHALL require its API provider to be
  `"openrouter"` (phase-1 gate) and SHALL NOT require `opencode_model_id` to
  be present.
- [x] **MODEL-POLICY-003** — When an `opencode` runner's `model_policy` is
  `"specific"` (explicit or defaulted), the system SHALL continue to require
  `opencode_model_id` to be present, unchanged from prior behavior.
- [x] **MODEL-POLICY-004** — `Runner#free_model_policy?` SHALL be true for
  the legacy `openrouter_free` runner key and for any `opencode` runner with
  `model_policy == "free"`. The `tier_model_ids`/`tier_models` validations
  that require free-pricing `LlmModel` rows, and their runner-compatibility
  counterparts that skip the generic compatibility check, SHALL key off this
  predicate rather than the `openrouter_free` runner key alone.

## Defaults and Display

- [x] **MODEL-POLICY-005** — When a `free_model_policy?` runner (legacy or
  config-driven) saves with blank `tier_model_ids`, `sync_direct_outbound_tier_models`
  SHALL curate them from `FreeModels::DefaultTierModels`, and
  `clear_stale_direct_outbound_tier_models` SHALL NOT clear an already-curated
  mapping on unrelated attribute saves.
- [x] **MODEL-POLICY-006** — `Runner#display_name` for a free-policy
  `opencode` runner without an explicit `name` SHALL render
  `"OpenCode Free (<API provider label>)"` (e.g. `"OpenCode Free (OpenRouter)"`),
  with the existing `" (API Key)"` suffix for api_key auth. The legacy
  `openrouter_free` display path is unchanged.

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

- [x] **MODEL-POLICY-009** — Runtime dispatch
  (`agent_harness_runner_runtime`/`requires_direct_outbound?`) and free-model
  rotation (`FreeModels::Rotation`) SHALL recognize `model_policy == "free"`
  on `opencode` runners the same way they recognize the legacy
  `openrouter_free` runner key, including rate-limit recovery snapshots keyed
  by the runner's routing identifier.
- [x] **MODEL-POLICY-011** — A free-policy `opencode` runner (`model_policy
  == "free"`) SHALL fail validation with an error on `:enabled_for_chat` if
  `enabled_for_chat` is true, on create, update, or any other save path.
  Chat dispatch does not yet resolve a free-tier model for policy-based free
  runners, so this validation is the enforcement point that prevents a
  free-policy runner from silently falling through to a paid default model
  in chat — regardless of the `enabled_for_chat` column's `true` DB default
  or a save that bypasses `RunnersController`. The legacy `openrouter_free`
  runner key is unaffected. Deferred: relax once chat dispatch resolves a
  free-tier model for policy-based free runners.

## Deferred

- [D] **MODEL-POLICY-010** — Re-scoping `Runner.single_instance_runner_key?`
  (the "Add Runner" UI-list helper) from a bare runner-key check onto the
  `free_model_policy?` config predicate. Deferred to the
  `openrouter_free` -> `opencode` migration issue; the real uniqueness
  invariant is enforced today by MODEL-POLICY-007 regardless of what the
  "Add Runner" list shows.
