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

This segment covers catalog synchronization only. Runner execution, rotation,
and request-time data-classification routing remain covered by their existing
code paths and RDRs.

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
- Maintain a separate catalog of OpenRouter model IDs with at least one
  advertised zero-data-retention (ZDR) inference endpoint, including paid and
  free models.

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

### `OpenrouterZdr::Sync`

The ZDR sync consumes `GET /api/v1/endpoints/zdr`, whose records describe
eligible *endpoints*, not an inferred provider or model-wide privacy policy.
It groups records by their concrete `model_id`; a model is a catalog candidate
when at least one advertised endpoint maps to that ID. The sync stores the
endpoint records as eligibility evidence and updates the matching `LlmModel`
row's explicit ZDR eligibility flag. It creates a catalog row when no existing
row describes an eligible paid or free model, preserving existing model
metadata when the row already belongs to another catalog owner.

Free rows created only from the ZDR endpoint feed are marked as ZDR-catalog
rows. `FreeModels::Sync` leaves those rows outside its free-list withdrawal
scope until the general OpenRouter models feed has itself synced the row. This
keeps the existing free-catalog ownership and deactivation lifecycle intact.

Successful refreshes are authoritative, including a valid empty endpoint list:
they clear eligibility withdrawn from the feed and record the successful
timestamp. Invalid payloads and transport failures do not clear existing
eligibility. Instead, they record the failed attempt and an unavailability
reason while preserving the last successful timestamp and last-known catalog.

`OpenrouterZdr::EligibleModels` is the query interface for runner setup. It
returns only active, currently advertised-eligible catalog rows and applies the
existing project provider permission and `Runners::ModelCompatibility` checks.
Its `freshness` query exposes the latest successful and attempted refresh plus
any unavailability reason, so consumers can distinguish last-known data from a
newly verified catalog.
The catalog is advisory: request-time `provider.zdr` enforcement remains the
authority for inference routing.

### `OpenrouterZdr::SyncJob`

The ZDR endpoint catalog refresh runs daily on the maintenance queue with
single-flight concurrency, independently from the existing free-model sync.

### `FreeModels::SyncJob`

The job is a daily GoodJob cron entry. It:

- runs on the maintenance queue
- enforces single-flight concurrency
- delegates its business work entirely to `FreeModels::Sync`

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
