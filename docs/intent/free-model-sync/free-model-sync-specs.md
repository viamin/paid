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

- [x] **OPENROUTER-ZDR-CATALOG-001** — When the ZDR catalog refresh runs, the
  system SHALL fetch OpenRouter's `/api/v1/endpoints/zdr` response and map each
  advertised endpoint to its `model_id`, including paid and free models.
- [x] **OPENROUTER-ZDR-CATALOG-002** — When one or more advertised ZDR
  endpoints share a model id, the system SHALL expose that model as eligible
  and retain the endpoint metadata; eligibility SHALL not be inferred from
  endpoint price, vendor, or provider-wide policy.
- [x] **OPENROUTER-ZDR-CATALOG-003** — When a successful ZDR refresh omits a
  previously eligible model, the system SHALL withdraw that eligibility while
  preserving unrelated free-catalog and seeded model ownership.
- [x] **OPENROUTER-ZDR-CATALOG-004** — When a ZDR response is unavailable or
  malformed, the system SHALL preserve the last successful eligibility data and
  mark its freshness unavailable instead of representing it as a verified empty
  catalog.
- [x] **OPENROUTER-ZDR-CATALOG-005** — When runner setup requests ZDR-only
  options, the system SHALL return only active advertised ZDR-eligible catalog
  models after applying existing runner compatibility filtering.
