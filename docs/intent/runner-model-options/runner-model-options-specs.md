# EARS Specs: Runner Model Options

> Testable claims for `Runners::ModelOptions`, the single source of truth for
> model choices per `(runner_key, api_provider, auth_type)`. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target across specs, tests, and code (`grep -r RUNNER-MODEL-OPTIONS-001`).

## Catalog Entries

- [x] **RUNNER-MODEL-OPTIONS-001** — When `Runners::ModelOptions.call` runs
  for a provider with active catalog rows, the system SHALL return one
  `:model` entry per active provider-scoped row, ordered by `family` then
  descending `capability_score`, each entry carrying the catalog `model_id`
  as its value, `display_name` as its label, the optgroup `family` (provider
  fallback when blank), and the catalog record.
- [x] **RUNNER-MODEL-OPTIONS-002** — When a candidate model is unsupported
  per `Runners::ModelCompatibility` (RDR-040) for the given
  `(runner_key, auth_type)`, the system SHALL exclude it from the option
  list; `unknown` compatibility results SHALL remain selectable.
- [x] **RUNNER-MODEL-OPTIONS-003** — When `api_provider` is `openrouter`, the
  system SHALL include both `provider == "openrouter"` rows and
  `catalog_source == "openrouter_sync"` rows (synced free models), so the
  dropdown offers the Pareto row and synced free models alongside other
  OpenRouter rows.

## Free Policy Entry

- [x] **RUNNER-MODEL-OPTIONS-004** — When `runner_key` is one of
  `opencode`, `kilocode`, `pi`, or `omp` and `api_provider` is
  `openrouter`, the system SHALL prepend a `:free_policy` entry with value
  `"free"`; for any other `(runner_key, api_provider)` pair the system
  SHALL NOT offer it.

## Custom Sentinel

- [x] **RUNNER-MODEL-OPTIONS-005** — When options are built, the system
  SHALL append a trailing `:custom` entry whose value is
  `LlmModel::CUSTOM_MODEL_OPTION`; when the provider has no active catalog
  rows, that sentinel SHALL be the only entry (DIRECT-OUTBOUND-CATALOG-005
  degradation rule).

## Defaults Reuse

- [x] **RUNNER-MODEL-OPTIONS-006** — When `Runners::DefaultTierModelIds`
  computes standard-provider tier defaults, it SHALL derive them from
  `Runners::ModelOptions` model entries (highest-capability compatible entry
  per tier) so tier defaults and dropdown options cannot diverge.
  *Code:* `Runners::DefaultTierModelIds`.
