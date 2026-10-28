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

- [x] **FREE-MODEL-SYNC-009** — When the ZDR catalog refresh runs, the system
  SHALL fetch OpenRouter's `/api/v1/endpoints/zdr` endpoint list and identify
  candidate models exclusively from endpoint records with a concrete
  `model_id`, including both paid and free models.
- [x] **FREE-MODEL-SYNC-010** — When one or more eligible endpoint records map
  to a model id, the system SHALL upsert that model's endpoint metadata and
  mark it `openrouter_zdr_eligible`; it SHALL not derive eligibility from
  price, vendor, or provider-wide policy.
- [x] **FREE-MODEL-SYNC-011** — When a successful ZDR response no longer lists
  a previously eligible model id, the system SHALL withdraw only its ZDR
  eligibility and deactivate a ZDR-owned catalog row, while preserving the
  existing free-catalog ownership and deactivation rules.
- [x] **FREE-MODEL-SYNC-012** — When the ZDR endpoint request fails or is
  malformed, the system SHALL preserve last-known candidates and record the
  refresh as unavailable; when a valid response is empty, it SHALL record a
  successful refresh and withdraw all prior eligibility.
- [x] **FREE-MODEL-SYNC-013** — When eligible ZDR models are queried for an
  OpenRouter runner, the system SHALL return active eligible candidates with
  their catalog metadata and freshness state, applying the existing runner
  compatibility filtering; OpenRouter request-time ZDR enforcement remains
  authoritative.
