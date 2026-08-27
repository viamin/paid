# EARS Specs: Direct-Outbound Model Catalog Coverage

> Testable claims for seed catalog coverage of `Runner::DIRECT_OUTBOUND_API_PROVIDERS`
> and the openrouter/pareto-code row. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target across specs,
> tests, and code (`grep -r DIRECT-OUTBOUND-CATALOG-001`).

## Coverage

- [x] **DIRECT-OUTBOUND-CATALOG-001** — When
  `Models::SeedKnownModels.call` runs, the system SHALL create or update at
  least one active `LlmModel` row per `service_type` declared in
  `Runner::DIRECT_OUTBOUND_API_PROVIDERS`.
- [x] **DIRECT-OUTBOUND-CATALOG-002** — When seeding runs more than once with
  unchanged inputs, the system SHALL leave every previously seeded row's
  attributes unchanged (idempotent upsert, no spurious `updated_at` touches).

## Pareto Row

- [x] **DIRECT-OUTBOUND-CATALOG-003** — When
  `Models::SeedKnownModels.call` seeds the `openrouter/pareto-code` row, the
  system SHALL set `provider: "openrouter"`, `catalog_source: "seeded"`, and
  `pricing_tier: "paid"`.
- [x] **DIRECT-OUTBOUND-CATALOG-004** — When `FreeModels::Sync` runs, the
  system SHALL NOT deactivate or otherwise modify the `openrouter/pareto-code`
  row, because it is scoped to `catalog_source: "seeded"`, outside
  `LlmModel.openrouter_synced_free`.

## Degradation Contract

- [x] **DIRECT-OUTBOUND-CATALOG-005** — When a caller requests dropdown
  options for a direct-outbound provider with no active catalog rows, the
  system SHALL return an empty relation from `LlmModel.dropdown_options_for`
  so the caller can render `LlmModel::CUSTOM_MODEL_OPTION` alone instead of an
  empty select.
