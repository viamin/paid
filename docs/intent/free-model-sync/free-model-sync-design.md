---
parent: PAID
prefix: FREE-MODEL-SYNC
---

# Free Model Sync Design

## Context

Paid already treats free models as first-class `LlmModel` rows and exposes
them through free-policy direct-outbound runners (`model_policy: "free"`;
RDR-065, #3671). What is missing is the catalog ingestion path: the
application must fetch OpenRouter's live free-model list, classify the
models into Paid's existing tier semantics, and keep the catalog current as
models appear, expire, or disappear.

This segment covers the daily synchronization paths only. Runner execution,
rotation, and request-time data-classification routing remain covered by their
existing code paths and RDRs.

## Goals

- Pull OpenRouter's model catalog from `GET /api/v1/models`.
- Persist only fully free models into `LlmModel` with
  `catalog_source: "openrouter_sync"` and `pricing_tier: "free"`.
- Derive capability score and tier mechanically from stable model metadata so
  the existing model-selection and tier-based runner code can reuse the synced
  catalog without bespoke branches.
- Preserve weak-quality models in the catalog, but mark them so default runner
  selection can avoid them.
- Keep the sync idempotent and mark no-longer-listed synced models inactive.
- Maintain a separate snapshot of the OpenRouter endpoint-level ZDR catalog,
  including both paid and free model IDs, for an explicit setup-time query.

## Design

### `FreeModels::Client`

The client is a thin HTTP wrapper around OpenRouter's models endpoint. It:

- performs a single `GET https://openrouter.ai/api/v1/models`
- applies explicit open/read timeouts
- parses the JSON payload
- returns the `data` array as an array of hashes
- raises typed errors for transport failures, timeouts, invalid JSON, and
  unexpected response statuses

The client stays mechanical: no filtering or catalog decisions happen here.

### `FreeModels::Classify`

Classification is a deterministic heuristic that turns API metadata into
Paid-native `capability_score` and `tier` values:

- base score `3.0`
- context window bonuses for `128K+`, `256K+`, and `1M+`
- tool support bonus
- reasoning support bonus
- output-token bonuses
- multimodal bonus when image/video input is supported

The tier mapping is:

- `high` when score `>= 8`
- `mid` when score `>= 6`
- `low` otherwise

### `FreeModels::QualityFilter`

The quality filter is a constant policy surface, not a separate persistence
concept. Models remain in the catalog, but the sync writes
`metadata["below_quality_bar"] = true` when they fail the current minimum:

- context window at least `128_000`
- tool support required

### `FreeModels::Sync`

The sync service:

1. fetches model payloads through `FreeModels::Client`
2. filters to models whose prompt and completion pricing are both `"0"`
3. upserts `LlmModel` rows keyed by `model_id`
4. writes the full upstream payload into `metadata`, merged with local markers
   such as `below_quality_bar`
5. links `free_variant_of_id` by stripping a trailing `:free` suffix and looking
   up the paid row by `model_id`
6. deactivates previously synced rows that were not present in the latest free
   result set
7. logs a structured sync summary

The sync owns only rows with `catalog_source: "openrouter_sync"`. It must never
mutate unrelated seeded or manual catalog entries.

### `FreeModels::SyncJob`

The job is a daily GoodJob cron entry. It:

- runs on the maintenance queue
- enforces single-flight concurrency
- delegates its business work entirely to `FreeModels::Sync`

### `OpenRouter::ZdrSync`

OpenRouter's `GET /api/v1/endpoints/zdr` response is an endpoint catalog, not
a model catalog: several advertised ZDR endpoints can map to the same
`model_id`. `OpenRouter::ZdrSync` groups the response by that concrete model
ID, stores every advertised endpoint as entry metadata, and materializes a
catalog row only when no existing `LlmModel` owns that ID. The materialized row
uses `catalog_source: "openrouter_zdr_sync"`; existing seeded and free-sync
rows remain owned by their respective synchronizers.

An eligibility entry links each eligible model to the singleton ZDR catalog
snapshot. A successful refresh atomically replaces those entries and records a
success timestamp, including when the response is a valid empty array. It
deactivates only materialized ZDR rows whose eligibility was withdrawn. An
unavailable, malformed, or failed refresh instead records the failed attempt
and error, preserves the previous entries, and marks the snapshot unavailable.

`OpenRouterZdrCatalog#eligible_models` is the query interface for setup code.
It returns active catalog rows with advertised eligibility and exposes the
snapshot freshness fields alongside them. Consumers retain their normal
compatibility, capability, and project-policy filtering; the catalog is only a
candidate list. `provider.zdr` remains the request-time authority.

### Boundaries

ZDR classifies OpenRouter inference endpoints only. It neither asserts Paid's
own retention behavior nor creates an automatic ZDR runner profile. Pricing is
stored as endpoint metadata and can label a materialized model for display,
but never determines ZDR eligibility.

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
