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

This segment covers the daily synchronization path only. Runner execution,
rotation, and data-classification routing remain covered by their existing code
paths and RDRs.

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

### `OpenrouterZdr::Sync`

The ZDR catalog is a separate synchronization path sourced from
`GET /api/v1/endpoints/zdr`. Each endpoint payload advertises one concrete
`model_id`; a model is eligible when at least one endpoint with that id appears
in a successful response. Eligibility is not inferred from endpoint pricing,
the upstream model vendor, or a provider-wide retention policy.

The sync aggregates endpoint payloads by `model_id`, then upserts model
metadata useful to runner setup. New rows are owned by
`catalog_source: "openrouter_zdr"`; existing free-sync, seeded, and manual rows
retain their ownership and receive only ZDR metadata. The per-model metadata
records the observed endpoints and the successful-refresh timestamp.

On a successful refresh, rows no longer represented by an endpoint lose ZDR
eligibility. ZDR-owned rows are deactivated only when their eligibility is
withdrawn; the free-model sync continues to own free-catalog activation and
deactivation unchanged.

`OpenrouterZdrCatalogRefresh` persists the last attempted and successful
timestamps plus the most recent failure. An unavailable or malformed refresh
preserves the last successful eligibility rows and marks the catalog
unavailable. A successful empty response instead clears eligibility and records
a successful empty snapshot.

### `OpenrouterZdr::SyncJob`

The ZDR sync runs daily on the maintenance queue and serializes concurrent
executions. It delegates all catalog behavior to `OpenrouterZdr::Sync`.

### `OpenrouterZdr::Catalog`

The catalog query exposes eligible models together with refresh freshness. It
uses the existing active catalog, runner compatibility, and optional project
provider restrictions; it does not assert that runtime routing will accept the
selected model. Runtime `provider.zdr` enforcement remains authoritative.

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
- ZDR eligibility is endpoint-level routing evidence, not a statement about
  Paid run-data retention and not an automatic model-selection profile.
