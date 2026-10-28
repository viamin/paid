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

## OpenRouter ZDR Endpoint Catalog

- [x] **FREE-MODEL-SYNC-009** — When the ZDR catalog refresh succeeds, the
  system SHALL map every advertised endpoint from OpenRouter's
  `/api/v1/endpoints/zdr` response to its concrete `model_id`, deduplicate
  multiple endpoints for the same model, and retain endpoint metadata for
  both paid and free models without deriving eligibility from price, vendor, or
  provider-wide policy.
- [x] **FREE-MODEL-SYNC-010** — When a ZDR endpoint names a model absent from
  the local catalog, the system SHALL materialize an active
  `openrouter_zdr_sync` catalog row with the endpoint's model metadata; it
  SHALL not overwrite rows owned by the seeded or free-model synchronizers.
- [x] **FREE-MODEL-SYNC-011** — When a ZDR refresh succeeds, including with a
  valid empty endpoint array, the system SHALL atomically replace eligibility,
  mark the snapshot successfully refreshed, and remove withdrawn eligibility
  while deactivating only ZDR-materialized rows.
- [x] **FREE-MODEL-SYNC-012** — When a ZDR refresh fails or has an invalid
  response, the system SHALL preserve the last successful eligibility set and
  its timestamp, record the failed attempt as unavailable, and never present
  that retained set as newly verified.
- [x] **FREE-MODEL-SYNC-013** — When runner setup queries advertised
  ZDR-eligible models, the system SHALL return only active eligible catalog
  rows together with snapshot freshness, while existing runner compatibility,
  capability, and project restrictions remain in force and request-time
  `provider.zdr` enforcement remains authoritative.
