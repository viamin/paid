# EARS Specs: Model Availability Reconciliation

> Testable claims for distinguishing catalog snapshot defaults, operator
> decisions, and runner/auth/account-scoped availability evidence.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **MODEL-AVAILABILITY-001** — When `ModelAvailabilityCheck` evidence is
  recorded, the system SHALL scope it by `llm_model`, `runner_key`,
  `auth_type`, and an optional `account`, and SHALL mark it `available` or
  `unavailable` with a `source`, so one account's rejection cannot be read as
  another account's or context's availability.
  *Code:* `ModelAvailabilityCheck`.

- [x] **MODEL-AVAILABILITY-002** — When an operator calls
  `LlmModel#operator_disable!` or `#operator_enable!`, the system SHALL
  persist `operator_active_override` alongside `active`, and scheduled catalog
  sync SHALL preserve that value on every subsequent run instead of
  reapplying the snapshot default.
  *Code:* `LlmModel`, `Models::SeedKnownModels`.

- [x] **MODEL-AVAILABILITY-003** — When `Models::SeedKnownModels` runs and a
  catalog row has no operator override, the system SHALL NOT reapply a
  snapshot `active: false` exclusion over a fresh, validated global
  `ModelAvailabilityCheck` showing the model available for at least one
  runner/auth context.
  *Code:* `Models::SeedKnownModels`.

- [x] **MODEL-AVAILABILITY-004** — When `Models::ReconcileAvailability.refresh!`
  runs for a runner/auth/account context, the system SHALL check each active
  catalog model for the matching provider at most once per
  `ModelAvailabilityCheck::DEFAULT_TTL`, deduplicating repeated checks within
  that window.
  *Code:* `Models::ReconcileAvailability`.

- [x] **MODEL-AVAILABILITY-005** — When
  `Models::ReconcileAvailability.record_rejection!` is called after a
  structured runtime rejection, the system SHALL upsert the scoped
  availability row as `unavailable`, bound `retry_count` by `MAX_RETRIES`, and
  SHALL NOT globally deactivate the `LlmModel` or mutate auth configuration.
  *Code:* `Models::ReconcileAvailability`.

- [x] **MODEL-AVAILABILITY-006** — When a policy-eligible replacement is
  requested after a rejection, the system SHALL rank remaining active,
  same-provider catalog candidates by tier proximity and capability score,
  excluding the rejected model and any candidate already recorded
  unavailable for the same context, and SHALL NOT hardcode a single model id
  as a universal fallback. When no eligible candidate remains, it SHALL
  report that explicitly rather than returning a rejected or invented model.
  *Code:* `Models::PolicyEligibleReplacement`.

- [x] **MODEL-AVAILABILITY-007** — When `Models::DetectCatalogDrift` runs
  against a healthy registry fetch, the system SHALL report catalog rows that
  are inactive, not operator-pinned inactive, and still present upstream as
  availability drift, distinct from new-model and deprecated-model drift.
  *Code:* `Models::DetectCatalogDrift`.
