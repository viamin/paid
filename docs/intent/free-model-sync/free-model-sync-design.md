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

It also covers the separate OpenRouter ZDR endpoint catalog used for explicit
runner setup choices. ZDR is an inference-endpoint routing property, not a
claim about Paid's retention of run data and not a replacement for runtime
provider routing enforcement.

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

The ZDR sync consumes `GET /api/v1/endpoints/zdr`. Each item in its `data`
array is an advertised eligible endpoint, not a model-wide provider policy.
The sync groups those endpoint records by their concrete `model_id` and marks
a model eligible when its group is nonempty. It persists the complete endpoint
evidence in model metadata so catalog consumers can distinguish the model
projection from request-time enforcement.

For models not already owned by the free catalog or another catalog source,
the sync creates an `LlmModel` with `catalog_source: "openrouter_zdr_sync"` and
the endpoint-supplied display, capability, pricing, and modality metadata.
Existing rows retain their catalog ownership; the ZDR sync changes only its
eligibility fields and its namespaced endpoint metadata. Free catalog refresh
continues to own free-row activation and deactivation.

A successful refresh is transactional: it marks current model ids eligible and
withdraws eligibility from every previously eligible model absent from that
response, including a successful empty response. A malformed or unavailable
response makes no eligibility changes. Instead, the singleton
`OpenrouterZdrCatalogStatus` records the attempt, failure state, and error
while preserving the last successful timestamp and last-known eligible rows.

`OpenrouterZdr::Catalog` is the query interface for active eligible models and
its freshness state. Runner setup continues to obtain entries through
`Runners::ModelOptions`; for OpenRouter it includes eligible ZDR rows alongside
the existing free-policy rows, then applies the existing compatibility filter.
Project-level provider restrictions remain enforced by their existing runner
setup path. The catalog is advisory for selection only; runtime `zdr`
enforcement remains authoritative.

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
- ZDR eligibility is represented only by endpoint evidence from OpenRouter;
  neither a model's price, vendor, nor an upstream provider-wide statement can
  make it eligible.
