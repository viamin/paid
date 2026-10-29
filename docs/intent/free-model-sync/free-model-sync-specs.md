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

- [x] **FREE-MODEL-SYNC-009** — When the OpenRouter ZDR catalog refresh runs,
  the system SHALL fetch `/api/v1/endpoints/zdr` and treat a concrete model as
  a candidate only when at least one structurally valid advertised endpoint
  supplies its `model_id`, without deriving eligibility from price, vendor, or
  provider-wide policy.
- [x] **FREE-MODEL-SYNC-010** — When an advertised ZDR endpoint names a model,
  the system SHALL retain its endpoint metadata and map it to an existing
  `LlmModel` or create a catalog row from that endpoint metadata without
  changing the lifecycle ownership of an existing seeded or free-synced row.
- [x] **FREE-MODEL-SYNC-011** — When a valid ZDR catalog refresh succeeds, the
  system SHALL make the refresh idempotent and remove eligibility withdrawn
  from the response while preserving its underlying `LlmModel` row.
- [x] **FREE-MODEL-SYNC-012** — When a ZDR refresh fails or its response is
  malformed, the system SHALL retain the last-known eligibility and record the
  catalog as unavailable; when a structurally valid empty response succeeds,
  it SHALL record a fresh successful empty catalog instead.
- [x] **FREE-MODEL-SYNC-013** — When a caller requests OpenRouter ZDR model
  candidates, the system SHALL return active eligible catalog models together
  with freshness state, and any runner setup flow using that explicit query
  SHALL continue to enforce its existing compatibility and project restrictions.
