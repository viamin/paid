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

## OpenRouter ZDR Catalog

- [x] **FREE-MODEL-SYNC-009** — When the ZDR catalog refresh succeeds, the
  system SHALL map endpoint `model_id` values to active `LlmModel` rows and
  mark a model ZDR-eligible when at least one advertised endpoint names it,
  including both paid and free models without inferring eligibility from price,
  vendor, or provider-wide policy.
- [x] **FREE-MODEL-SYNC-010** — When a successful ZDR catalog refresh omits a
  previously eligible model, the system SHALL remove that model's ZDR
  eligibility and deactivate only rows owned by the ZDR catalog.
- [x] **FREE-MODEL-SYNC-011** — When a ZDR catalog refresh fails or returns a
  malformed payload, the system SHALL preserve the last successful eligibility
  rows and expose the catalog as unavailable with its last successful
  freshness; when a refresh succeeds with no endpoints, it SHALL expose a
  successful empty catalog instead.
- [x] **FREE-MODEL-SYNC-012** — The ZDR catalog query SHALL return only active
  endpoint-eligible models and SHALL retain existing runner compatibility and
  applicable project provider restrictions; it SHALL not replace runtime
  `provider.zdr` enforcement.
- [x] **FREE-MODEL-SYNC-013** — The system SHALL refresh the OpenRouter ZDR
  catalog daily through a serialized maintenance job.
