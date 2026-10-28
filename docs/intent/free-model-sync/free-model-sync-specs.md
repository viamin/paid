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

- [x] **FREE-MODEL-SYNC-009** — When the ZDR catalog refresh runs, the system
  SHALL fetch OpenRouter's advertised `/api/v1/endpoints/zdr` inventory and
  map each advertised endpoint's concrete `model_id` to metadata from
  `/api/v1/models`; a model SHALL be a candidate when at least one advertised
  eligible endpoint maps to it, regardless of whether it is paid or free.
- [x] **FREE-MODEL-SYNC-010** — The system SHALL derive ZDR eligibility only
  from advertised endpoint membership, never from price, vendor, or a
  provider-wide policy, and SHALL retain the grouped endpoint/model metadata
  used to create runner-setup candidates.
- [x] **FREE-MODEL-SYNC-011** — When a ZDR refresh succeeds, the system SHALL
  idempotently upsert current eligibility, record its successful freshness,
  and mark eligibility absent from that successful response inactive; a
  successful empty response SHALL withdraw all prior eligibility.
- [x] **FREE-MODEL-SYNC-012** — When a ZDR refresh is unavailable, malformed,
  or cannot map an advertised endpoint to a model, the system SHALL preserve
  last-known eligibility and record explicit refresh unavailability rather
  than representing it as a successful empty catalog.
- [x] **FREE-MODEL-SYNC-013** — When a runner queries ZDR candidates, the
  system SHALL return only active advertised candidates that meet the existing
  runner compatibility, tool capability, verified-model, availability, and
  project-policy restrictions, together with the catalog freshness state;
  request-time OpenRouter ZDR enforcement remains authoritative.
