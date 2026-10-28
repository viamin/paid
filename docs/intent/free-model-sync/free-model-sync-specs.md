# EARS Specs: Free Model Sync

> Testable claims for OpenRouter free-model catalog sync. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r FREE-MODEL-SYNC-001`).

## Sync Lifecycle

- [x] **FREE-MODEL-SYNC-001** — When the daily free-model sync runs, the
  system SHALL fetch OpenRouter's `/api/v1/models` catalog and consider only
  models whose prompt and completion pricing are both `"0"` as free models to
  persist.
- [x] **FREE-MODEL-SYNC-002** — When a free model is persisted from the
  OpenRouter catalog, the system SHALL upsert an `LlmModel` row with
  `pricing_tier: "free"`, `catalog_source: "openrouter_sync"`, provider
  derived from the model-id prefix, conservative
  `data_training_risk: "possible"`, and the full upstream payload stored in
  `metadata`.
- [x] **FREE-MODEL-SYNC-003** — When a free model is persisted, the system
  SHALL derive its `capability_score` and `tier` from the deterministic
  free-model classification heuristic.
- [x] **FREE-MODEL-SYNC-004** — When a synced free model fails the free-model
  minimum criteria, the system SHALL set `metadata["below_quality_bar"] = true`
  while still keeping the model active in the catalog.
- [x] **FREE-MODEL-SYNC-005** — When a synced free model id ends in `:free`
  and a paid counterpart row exists for the stripped id, the system SHALL link
  the free row to that paid row through `free_variant_of_id`.
- [x] **FREE-MODEL-SYNC-006** — When a previously synced free model is absent
  from a later OpenRouter free-model catalog response, the system SHALL mark
  that synced row inactive instead of deleting it.
- [x] **FREE-MODEL-SYNC-007** — When OpenRouter supplies an expiration date for
  a free model, the system SHALL persist it to `LlmModel.expires_at`.
- [x] **FREE-MODEL-SYNC-008** — When the daily free-model sync job is
  scheduled, the system SHALL enqueue `FreeModels::SyncJob` once per day
  through GoodJob cron and serialize concurrent executions.

## OpenRouter ZDR endpoint catalog

- [x] **OPENROUTER-ZDR-001** — When the ZDR sync runs, the system SHALL fetch
  OpenRouter's endpoint-level ZDR catalog and validate concrete endpoint model
  identifiers without inferring eligibility from price, vendor, or provider.
- [x] **OPENROUTER-ZDR-002** — When an advertised ZDR endpoint is received,
  the system SHALL map its concrete model id and metadata to an active
  `LlmModel`, including both paid and free models.
- [x] **OPENROUTER-ZDR-003** — When a successful refresh completes, the system
  SHALL be idempotent and remove withdrawn endpoint eligibility while leaving
  free-catalog ownership and deactivation rules unchanged.
- [x] **OPENROUTER-ZDR-004** — When a valid refresh returns no endpoints, the
  system SHALL record an available successful empty catalog and remove prior
  ZDR eligibility.
- [x] **OPENROUTER-ZDR-005** — When a refresh fails, the system SHALL preserve
  the last-known endpoint snapshot and record explicit unavailable freshness
  with the failure and last successful timestamp.
- [x] **OPENROUTER-ZDR-006** — When the endpoint response is malformed, the
  system SHALL fail the refresh without replacing the last-known snapshot.
- [x] **OPENROUTER-ZDR-007** — When querying eligible models, the system SHALL
  return models with at least one advertised endpoint while retaining active
  catalog, capability ordering, runner compatibility, and project-provider
  restrictions.
