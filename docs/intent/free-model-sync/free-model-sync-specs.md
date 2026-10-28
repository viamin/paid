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

## Advertised ZDR Endpoint Catalog

- [x] **FREE-MODEL-SYNC-009** — When the ZDR catalog refresh receives an
  OpenRouter `/api/v1/endpoints/zdr` response containing one or more valid
  endpoint records for a model ID, the system SHALL expose that exact model ID
  as an eligible candidate, regardless of whether its advertised endpoint price
  is free or paid.
- [x] **FREE-MODEL-SYNC-010** — When the ZDR catalog refresh persists an
  eligible model, the system SHALL retain runner-setup metadata and all
  advertised endpoint records for that model, and SHALL not infer eligibility
  from model vendor, provider-wide policy, or price.
- [x] **FREE-MODEL-SYNC-011** — When a successful ZDR refresh omits every
  advertised eligible endpoint for a previously eligible model, the system
  SHALL withdraw that model's eligibility and deactivate it only when the ZDR
  catalog exclusively owns its row.
- [x] **FREE-MODEL-SYNC-012** — When a ZDR refresh succeeds, including with an
  empty endpoint array, the system SHALL mark the catalog available with its
  successful refresh time; when the request or payload fails, it SHALL mark the
  catalog unavailable and preserve the last successfully eligible models.
- [x] **FREE-MODEL-SYNC-013** — When runner setup queries eligible ZDR models,
  the system SHALL return the catalog freshness state and only models that
  remain eligible, active, permitted by the existing OpenRouter provider
  selection, and compatible with the selected runner and authentication mode.
