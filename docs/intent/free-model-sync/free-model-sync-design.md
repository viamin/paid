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

OpenRouter's advertised Zero Data Retention (ZDR) endpoint inventory is a
separate catalog concern. It informs explicit runner setup choices but does
not replace OpenRouter's request-time `provider.zdr` enforcement and does not
describe Paid's own run-data retention. It neither changes the existing Free
policy nor creates an automatic ZDR selection profile.

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

The ZDR sync obtains OpenRouter's `/api/v1/endpoints/zdr` endpoint list and
the normal `/api/v1/models` metadata catalog. An endpoint is eligible only
because it appears in the advertised ZDR response; the sync groups those
endpoint rows by their concrete `model_id` and creates one candidate per model
with one or more advertised endpoints. It must never infer eligibility from a
model's price, vendor, or a provider-wide policy.

For each eligible model, the sync stores the endpoint and model metadata in
`OpenrouterZdrModel`. It creates or refreshes a Paid `LlmModel` only when the
row is absent or already owned by the ZDR catalog. A free-model row remains
owned by `FreeModels::Sync`, preserving both its metadata and its independent
deactivation lifecycle. Paid and free ZDR candidates are both supported.

A successful refresh transactionally upserts the current candidates,
timestamps their verification, and marks withdrawn ZDR eligibility inactive.
An empty but valid endpoint response is therefore a successful empty catalog
and withdraws all prior eligibility. A transport, status, JSON, shape, or
endpoint-to-model mapping failure leaves the last-known eligibility untouched;
instead the singleton catalog state records the attempted time and explicit
unavailability/error. A later successful refresh clears that unavailable
state. This makes a stale successful snapshot distinguishable from newly
verified data.

`OpenrouterZdr::SyncJob` runs daily on the maintenance queue with its own
single-flight key, independently of the Free sync so an unavailable catalog
does not interfere with the existing Free policy refresh.

### `OpenrouterZdr::EligibleModels`

This query interface returns active, advertised-ZDR `LlmModel` candidates and
their freshness state. It uses the existing `Runners::ModelOptions` path for
runner compatibility, requires the existing tool capability needed by runner
setup, and applies verified-model, availability, and project policy checks.
It is a setup catalog query only; callers must continue to send and enforce
OpenRouter's runtime `provider.zdr` routing option.

## Trace Notes

- The provider stored on synced free rows is the upstream model-id prefix (for
  example `deepseek` from `deepseek/deepseek-v4-flash:free`), not `"openrouter"`.
- Catalog queries that mean “OpenRouter-synced free models” must therefore key
  off `catalog_source: "openrouter_sync"` plus `pricing_tier: "free"`, not a
  hard-coded provider string.
