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

## Provider-Derived Runner Setup

- [x] **DIRECT-OUTBOUND-CATALOG-006** — When the runner form renders an
  API-key direct-outbound runner (`opencode`, `kilocode`, `pi`, `omp`), the
  system SHALL derive the effective provider from the selected API key's
  `api_service_type` instead of rendering a second `api_provider` form control.
- [x] **DIRECT-OUTBOUND-CATALOG-007** — When the selected API key changes for
  an API-key direct-outbound runner, the system SHALL refresh the model
  dropdown to the catalog rows for that key's `api_service_type`.
- [x] **DIRECT-OUTBOUND-CATALOG-008** — When a new or updated API-key
  direct-outbound runner is saved, the system SHALL stop persisting
  `config[runner_key]["api_provider"]`; legacy stored values remain a fallback
  only for pre-existing rows that have not yet been rewritten.
- [x] **DIRECT-OUTBOUND-CATALOG-009** — When the runner form renders the model
  dropdown for an existing API-key direct-outbound runner whose configured
  model is outside the active catalog for its derived provider (deactivated
  or manually entered), the system SHALL still render that model as a
  selectable, pre-selected option, so saving an unrelated field never
  silently clears or invalidates it.
- [x] **DIRECT-OUTBOUND-CATALOG-010** — When the derived provider for an
  API-key direct-outbound runner has no active catalog rows and no currently
  configured model to preserve, the runner form SHALL render a manual
  model-id text field instead of a permanently disabled, empty select.
