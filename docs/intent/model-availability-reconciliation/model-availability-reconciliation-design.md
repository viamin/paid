---
parent: PAID
prefix: MODEL-AVAILABILITY
---

# Model Availability Reconciliation Design

> Companion to [`docs/intent/model-selection/`](../model-selection/) and
> [`docs/intent/direct-outbound-model-catalog/`](../direct-outbound-model-catalog/).
> Addresses issue #3945: scheduled catalog sync reapplied a static snapshot
> `active` flag over evidence that a model was actually available under a
> given runner/auth context (e.g. Codex subscription), and the catalog had no
> way to tell an operator's explicit disable apart from the sync's own
> default.

## Context

`Models::SeedKnownModels` treats `LlmModel#active` as a single global flag
derived from `KNOWN_MODELS`, and reassigns it on every run
(`model.active = snapshot_attrs.fetch(:active, true)`). That conflates three
different things that must stay distinguishable:

1. The **catalog snapshot default** — a judgment call baked into
   `KNOWN_MODELS` at authoring time.
2. An **operator's explicit decision** to enable or disable a model,
   independent of the snapshot.
3. **Runtime evidence** — a specific runner/auth/account context actually
   succeeded or was rejected using the model.

Without a place to record (2) and (3), every sync silently overwrites both
with (1).

## Goals

- Give operators a way to pin a model's active state that scheduled sync
  cannot undo.
- Record runner/auth/account-scoped availability evidence separately from the
  global catalog row, so validated availability survives the next sync even
  when the snapshot default disagrees.
- Let a structured runtime rejection (a provider/CLI declining a model for a
  specific auth context) update that evidence without globally deactivating
  the model or mutating auth.
- Surface catalog rows that are inactive but still present upstream as
  *availability drift*, distinct from "new model" and "deprecated model"
  drift.
- Never let policy-eligible replacement selection default to one hardcoded
  "universal" fallback model id — rank from current catalog/tier data instead.

## Boundary with Runtime Recovery

Runner-local verified selections are owned by RUNNER-FALLBACK-007 through
RUNNER-FALLBACK-009. They persist in `RunnerState` under the runner's state key and a
fingerprint including its concrete runner ID and auth/configuration, without the periodic check TTL.
They are execution evidence, while a `ModelAvailabilityCheck` whose source is
`agent_harness_compat` records static compatibility. A global catalog refresh or
static compatibility check cannot erase runner-local verification. Live recovery
does not promote one account's availability to the global catalog and always
honors `operator_active_override: false`.

## Non-goals

- Wiring a preflight retry into the live run/container execution path.
- Reclassifying provider error text at the point a run fails.
- Live, per-runner discovery and durable replacement selection, which belong to
  the runtime recovery segment. This segment consumes the static
  `Runners::ModelCompatibility` / `AgentHarness.model_compatibility` contract.

## Design

### `LlmModel#operator_active_override`

A nullable boolean column. `nil` means "no explicit operator decision —
scheduled sync owns this row's `active` flag." `true`/`false` means an
operator called `#operator_enable!` / `#operator_disable!`, and sync must
preserve that value verbatim rather than reapplying the snapshot default.

### `ModelAvailabilityCheck`

One row per `(llm_model, runner_key, auth_type, account)` reconciliation
result (`account` nullable for an account-agnostic/global context). Captures
`status` (`available`/`unavailable`), `source`, `reason`,
`incompatibility_type`, `replacement_model_id`, `attempted_model_id`,
`retry_count`, `checked_at`, and `expires_at`. This is the durable answer to
"was this model actually usable for this runner/auth/account, and when did we
last check" — independent of the global catalog `active` flag.

### `Models::ReconcileAvailability`

- `.refresh!(runner_key:, auth_type:, account: nil)` — periodic path, called
  from `ModelsSyncJob` after seeding. For each active catalog model matching
  the runner's provider, calls `Runners::ModelCompatibility` and upserts a
  `ModelAvailabilityCheck`. Skips rows whose existing check is still fresh
  (`ModelAvailabilityCheck::DEFAULT_TTL`) so the sweep is bounded and
  deduplicated rather than re-checking every model on every run.
- `.record_rejection!(llm_model:, runner_key:, auth_type:, account: nil,
  reason:, incompatibility_type:, attempted_model_id:)` — reactive path for a
  structured runtime rejection. Upserts the row as `unavailable`, bumps
  `retry_count` bounded by `MAX_RETRIES`, and returns a
  `Models::PolicyEligibleReplacement` candidate for a single preflight retry.
  It never deactivates the `LlmModel` globally and never touches auth
  configuration — those remain policy decisions for the caller (or #3943/#3944).

### `Models::PolicyEligibleReplacement`

Given a rejected model + runner/auth/account context, ranks the remaining
active catalog candidates for the same provider by tier proximity and
`capability_score`, excluding the rejected model and any candidate already
recorded `unavailable` for the same context. Selection is data-driven — it
never hardcodes a specific model id as a universal fallback.

### `Models::SeedKnownModels` change

`active` is computed with this precedence:

1. `operator_active_override`, if the row has one.
2. The snapshot default (`KNOWN_MODELS`'s `active:`, default `true`), unless
   there is a fresh, validated global (`account: nil`) `ModelAvailabilityCheck`
   showing the model `available` for at least one runner/auth context — in
   which case sync leaves the current `active` value alone instead of
   reapplying a stale snapshot exclusion.

### `Models::DetectCatalogDrift` addition

`availability_drift_for(provider)` reports catalog rows that are `active:
false`, not operator-pinned inactive (`operator_active_override != false`),
and still present in a healthy registry fetch — i.e. an automatic exclusion
that current evidence contradicts. This is additive to the existing
`new_models`/`deprecated_models` categories and feeds `ModelHealthCheckJob`
the same way.

## Trace Notes

- Tier assignment for a newly discovered model id remains a human/agent
  judgment call, filed via `Models::FileModelHealthIssue`'s existing
  remediation guidance (`KNOWN_MODELS` tier/category/capability_score are
  judgment calls) — consistent with ZFC. This segment does not auto-import
  arbitrary discovered models or infer tier from model names.
- `Runners::ModelCompatibility`'s `replacement_model_id` (from
  `AgentHarness::ModelCompatibility`) is informational only; it is never
  auto-applied by this segment.
