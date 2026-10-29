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

The same catalog boundary also records OpenRouter's advertised endpoint-level
Zero Data Retention (ZDR) eligibility. ZDR is a property of a particular
OpenRouter endpoint, not a price tier, vendor, or a statement about Paid's own
run-data retention. The endpoint catalog is a setup-time candidate list only;
request-time `provider.zdr` routing remains authoritative.

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

The ZDR sync fetches `GET /api/v1/endpoints/zdr` through a dedicated mechanical
client. Each returned endpoint is grouped by its concrete `model_id`; a model
is eligible when at least one advertised endpoint names it. The sync persists
the endpoint payloads, count, and last-seen time in `OpenrouterZdrModel` and
creates a catalog `LlmModel` only when the model is not already known. It does
not replace metadata or ownership on existing seeded or free-synced rows.

After a successful, structurally valid response, it removes eligibility rows
not present in that response. It never deactivates `LlmModel` rows: the free
sync remains the owner of free-row lifecycle and other catalog sources retain
their own lifecycle rules.

`OpenrouterZdrCatalog` is a singleton freshness record. A successful response,
including a valid empty `data` array, records `last_successful_at` and clears
unavailability. A transport, response, JSON, or structural failure records an
unavailable state while preserving both the last successful timestamp and the
last-known eligibility rows. This makes an unavailable refresh distinct from a
newly verified empty catalog.

### ZDR candidate query

`OpenrouterZdr::EligibleModels` returns active `LlmModel` rows joined to the
currently retained advertised eligibility rows together with catalog freshness.
`Runners::ModelOptions` can explicitly request this candidate set for an
OpenRouter setup flow; it continues to apply existing runner compatibility and
does not change the default model list or create an automatic ZDR profile.

### `OpenrouterZdr::SyncJob`

The ZDR refresh runs daily on the maintenance queue with single-flight
concurrency, staggered from the free-model refresh.

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
- An empty ZDR response is authoritative only after it passes endpoint response
  shape checks; failed refreshes preserve last-known results.
