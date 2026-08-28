# RDR-065: Runner Model Selection UX

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-27
- **Status**: Partially Implemented
- **Type**: Architecture + Runner UX
- **Priority**: P1
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md) (Agent CLI Abstraction), [RDR-008](RDR-008-model-selection.md) (Model Selection Strategy), [RDR-034](RDR-034-tier-based-runner-fallback.md) (Tier-Based Runner Fallback), [RDR-038](RDR-038-free-models-catalog-and-runner.md) (Free Models Catalog and Runner), [RDR-040](RDR-040-runner-model-compatibility-contracts.md) (Runner Model Compatibility Contracts), [RDR-064](RDR-064-container-agent-chat-mode.md) (Container Agent Chat Mode)
- **Related Issues**: #3663 (umbrella), #3665 (provider catalog seed gap), #3666 (`Runners::ModelOptions`), #3667 (key-derived `api_provider`), #3668 (`model_policy`), #3669 (form + flag), #3670 (data migration), #3671 (migration + flag cleanup), #3672 (RDR closeout audit), #3673 (Free-policy post-closeout port — explicit non-blocker)
- **Related Intent**: TBD
- **Related Tests**: TBD

## Implementation Status

RDR-065 is **partially implemented** as of 2026-08-27. The closeout audit in
[#3672](https://github.com/viamin/paid/issues/3672) found that the catalog
coverage, `Runners::ModelOptions`, key-derived provider behavior, and
`opencode` `model_policy` validation work shipped with test coverage, but the
rollout-guarded form cutover, free-policy dispatch, and
`openrouter_free`/`openrouter_pareto` migration/removal work did not.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Catalog coverage for direct-outbound providers plus seeded `openrouter/pareto-code` | Implemented | `app/services/models/seed_known_models.rb`; `spec/services/models/seed_known_models_spec.rb`; `spec/services/free_models/sync_spec.rb` |
| `Runners::ModelOptions` catalog/service-type compatibility filtering and sentinels | Implemented | `app/services/runners/model_options.rb`; `spec/services/runners/model_options_spec.rb`; `app/services/runners/default_tier_model_ids.rb` |
| Key-derived `api_provider` and grouped API-key form input | Implemented | `app/models/runner.rb`; `app/views/runners/_form.html.erb`; `app/javascript/controllers/runner_form_controller.js`; `spec/requests/runners_spec.rb` |
| `opencode` `model_policy` validation and persistence shape | Implemented | `app/models/runner.rb`; `app/controllers/runners_controller.rb`; `spec/models/runner_spec.rb`; `spec/requests/runners_spec.rb` |
| Rollout guard `runner_model_policy_form` defined, flipped, and cleaned up after default cutover | Gap | Flag definition is absent from `app/services/feature_flags.rb`; legacy form still renders in `app/views/runners/_form.html.erb`; tracked by [#3669](https://github.com/viamin/paid/issues/3669) |
| New form behavior and #3663 walkthroughs (OpenRouter Free/Pareto/specific/custom) | Gap | Current form still renders the direct-outbound select/text-input flow in `app/views/runners/_form.html.erb` and `app/javascript/controllers/runner_form_controller.js`; tracked by [#3669](https://github.com/viamin/paid/issues/3669) |
| Policy-based execution dispatch and rotation/governance parity for `model_policy == "free"` | Gap | `app/services/runners/resolve_tier_model.rb` does not read `model_policy`; `Runner#opencode_free_policy_runner_must_not_be_enabled` still blocks enabled free-policy OpenCode runners in `app/models/runner.rb`; tracked by [#3670](https://github.com/viamin/paid/issues/3670) |
| `openrouter_free` / `openrouter_pareto` migration to `opencode` + policy/model and legacy path removal | Gap | Legacy keys/constants and runtime branches remain in `app/models/runner.rb`, `lib/runner_support.rb`, and `app/temporal/activities/run_agent_activity.rb`; tracked by [#3671](https://github.com/viamin/paid/issues/3671) |

### 2026-08-27 Closeout

Audit report: [audit-report-2026-08-27-rdr-065.md](audit-report-2026-08-27-rdr-065.md).

What shipped:

- direct-outbound catalog seeding now covers the providers required for the
  dropdown UX and includes a seeded `openrouter/pareto-code` row
- `Runners::ModelOptions` exists as the dropdown/defaults source of truth and
  filters through `Runners::ModelCompatibility`
- the runner model now derives effective direct-outbound provider slugs from
  the selected API key and validates `opencode` `model_policy`

What remains open:

- the rollout guard from this RDR was never added, so there is no flagged
  legacy/new-form split and no flag cleanup to verify
- the direct-outbound form has not been converted to the final
  model-policy-driven UX described in this RDR
- execution dispatch still treats free-policy `opencode` as incomplete and the
  legacy `openrouter_free` / `openrouter_pareto` branches remain in place

Because those gaps are still open in
[#3669](https://github.com/viamin/paid/issues/3669),
[#3670](https://github.com/viamin/paid/issues/3670), and
[#3671](https://github.com/viamin/paid/issues/3671), this RDR cannot move to
`Implemented` yet and the umbrella issue [#3663](https://github.com/viamin/paid/issues/3663)
must remain open.

## Problem Statement

The runner configuration form for direct-outbound runners (`opencode`, `kilocode`, `pi`, `omp`) asks the user to type a model identifier with no discovery, no save-time catalog/compatibility validation, and no help for small-catalog providers. The same form also exposes two parallel controls — an **API Key** dropdown and an **API Provider** select — that encode the same fact and can disagree.

The concrete UX failures this RDR addresses:

1. **Freeform model input.** Today the user is presented with a free-text `Model ID` field. They must already know the exact model id accepted by the chosen provider (`anthropic/claude-sonnet-4.6`, `minimax/MiniMax-M3`, etc.). If they mistype, the configuration saves and the broken model surfaces as a runtime failure inside an agent run, surfacing through `Models::DetectBrokenRunnerModels` (RDR-040) days later.
2. **Redundant provider selection.** The `runner[config][<runner_key>][api_provider]` select encodes the same information already carried by the selected `ProviderApiKey#api_service_type`. The two controls can drift: a user can pick an Anthropic key and then choose `openrouter` as the provider.
3. **Conceptual inversion: pseudo-keys.** `openrouter_free` and `openrouter_pareto` look like runner *keys* in the "Add Runner" UI, but the underlying CLI is `opencode` (see `RunnerSupport::APP_RUNNER_TO_HARNESS_KEY`) and `openrouter_pareto` does not manage tiers — `Runners::ParetoExecutionPlan::PARETO_MODEL_ID` is hardcoded to `openrouter/pareto-code`. The pseudo-key presentation hides that these are *policies on OpenCode*, not independent runners.

The related umbrella issue #3663 documents these in user-facing terms; this RDR fixes them.

## Context

### Current Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Runner index page (subscription rows + openrouter_free + openrouter_pareto)│
└──────────────────────────────────────────────────┬───────────────────────┘
                                                   │
┌──────────────────────────────────────────────────▼───────────────────────┐
│ RunnersController#new / #edit                                              │
│  • Renders _form.html.erb                                                  │
│  • For direct-outbound runner keys:                                        │
│      - API Provider select (DIRECT_OUTBOUND_API_PROVIDERS / PI_API_PROVIDERS)
│      - Model ID text input (freeform)                                      │
│  • For openrouter_free / openrouter_pareto:                                │
│      - Runner already implies OpenRouter; api_provider select hidden       │
│      - Tier model dropdown (free runner) or no model UI (pareto runner)    │
│  • Subscription runners: no model field; harness runner chooses           │
└──────────────────────────────────────────────────┬───────────────────────┘
                                                   │
┌──────────────────────────────────────────────────▼───────────────────────┐
│ Runner save                                                                │
│  • validate :opencode_api_key_config_must_be_valid (and per-runner peers)   │
│  • validate :tier_model_ids_must_be_valid / :tier_model_ids_must_be_runner_compatible
│  • before_save :sync_direct_outbound_tier_models — materializes tier_models│
│  • before_save :ensure_manual_direct_outbound_catalog_entry — upserts the  │
│    typed model_id into LlmModel with catalog_source: "manual"              │
└──────────────────────────────────────────────────┬───────────────────────┘
                                                   │
┌──────────────────────────────────────────────────▼───────────────────────┐
│ Dispatch                                                                   │
│  • Runners::ResolveTierModel resolves (runner, tier) → model_id             │
│  • Runners::ModelCompatibility (RDR-040) is the runner/model filter layer  │
│  • Runners::ParetoExecutionPlan builds the Pareto runner's config         │
│  • Runners::FreeModelExecutionPlan + FreeModels::Rotation execute the Free  │
│    runner (RDR-038)                                                         │
└──────────────────────────────────────────────────────────────────────────┘
```

### Direct-Outbound Runner Configuration Today

The four direct-outbound runners in `RunnerSupport::APP_RUNNER_KEYS` (`opencode`, `kilocode`, `pi`, `omp`) each accept a per-runner `api_provider` and freeform `model_id`:

- `Runner::DIRECT_OUTBOUND_API_PROVIDERS` (`app/models/runner.rb:54`) — ten slugs (`openrouter`, `anthropic`, `openai`, `inception`, `deepseek`, `mistral`, `minimax`, `xai`, `zai`, `zai_coding`), each carrying a `:service_type`.
- `Runner::PI_API_PROVIDERS` (`app/models/runner.rb:109`) and `Runner::OMP_API_PROVIDERS` (alias) — nine slugs (`anthropic`, `openai`, `deepseek`, `google`, `mistral`, `minimax`, `xai`, `zai`, `openrouter`).
- For every entry in both maps, the `:service_type` equals the provider slug (D4 below).
- The runner exposes accessors `opencode_api_provider`/`opencode_model_id`, `kilocode_api_provider`/`kilocode_model_id`, `pi_api_provider`/`pi_model_id`, `omp_api_provider`/`omp_model_id`, and each is written by hand-rolled `<runner_key>_api_key_config_must_be_valid` validation methods.

### Free / Pareto Runners Today

`RunnerSupport::APP_RUNNER_TO_HARNESS_KEY` (`lib/runner_support.rb:30`) maps both `openrouter_free` and `openrouter_pareto` to the harness provider `opencode` — they are *policies on OpenCode*, not separate CLIs.

`Runner::OPENROUTER_FREE_RUNNER_KEY` and `Runner::OPENROUTER_PARETO_RUNNER_KEY` exist as runner keys because RDR-038 rejected "use existing runner keys" in favor of dedicated runner keys for discoverability (see Alternatives Considered in RDR-038). The Free runner uses `FreeModels::DefaultTierModels` for tier defaults and `FreeModels::Rotation` for rate-limit recovery. The Pareto runner hardcodes `PARETO_MODEL_ID = "openrouter/pareto-code"` (`app/services/runners/pareto_execution_plan.rb:10`) and manages no tier IDs.

`Runner.single_instance_runner_key?` (`app/models/runner.rb:768`) currently treats only `openrouter_free` as a single-instance runner, which is also the gating predicate for free-model rotation.

### Model Catalog Today

`Models::SeedKnownModels::KNOWN_MODELS` (`app/services/models/seed_known_models.rb:10`) seeds the `LlmModel` catalog from RubyLLM registry plus an app snapshot. Today that snapshot covers:

- `anthropic`, `openai`, `google`, `zai_coding`, `minimax`

Missing (planned in #3665): `deepseek`, `mistral`, `xai`, `zai`, `inception`.

OpenRouter free models arrive via `FreeModels::Sync` (`app/services/free_models/sync.rb`), which sets `pricing_tier: "free"` and `catalog_source: "openrouter_sync"`. `FreeModels::Sync#deactivate_missing_models!` scopes to `openrouter_synced_free`, so any `LlmModel` with `catalog_source: "openrouter_sync"` is deactivated when it disappears from the daily OpenRouter sync.

User-typed custom model ids land in the catalog via `LlmModel.upsert_manual_catalog_entry` (`app/models/llm_model.rb:100`) with `catalog_source: "manual"`. These are exempt from daily sync retirement and act as the freshness escape hatch.

### Why a Catalog-Driven Dropdown Is Safe Today

- The `LlmModel` catalog is already the source of truth for `Models::Select` and `Runners::ResolveTierModel`.
- `Models::DetectBrokenRunnerModels` and `Models::DetectContractDrift` (RDR-040) sweep recently failed runs and broken configs to surface and self-heal bad model ids over time.
- `LlmModel.upsert_manual_catalog_entry` already lets users register a model id that is not yet in the snapshot, so "the catalog does not have my model" is not a hard blocker.
- `Runners::ModelCompatibility` (RDR-040) is the established runner/model filtering layer the dropdown will reuse rather than introducing a new gate.

## Research Findings

The findings below are the verified code anchors that justify the decisions in this RDR.

### Pseudo-keys map to `opencode`

`RunnerSupport::APP_RUNNER_TO_HARNESS_KEY` (`lib/runner_support.rb:30`):

```ruby
APP_RUNNER_TO_HARNESS_KEY = {
  "openrouter_free" => "opencode",
  "openrouter_pareto" => "opencode"
}.freeze
```

Both pseudo-keys route to the `opencode` harness provider — they are policies on OpenCode, not independent runners. Evidence for D3.

### Pareto hardcodes a single model id

`Runners::ParetoExecutionPlan` (`app/services/runners/pareto_execution_plan.rb`):

```ruby
PARETO_MODEL_ID = "openrouter/pareto-code"
# ...
Result.new(
  config: {
    model: PARETO_MODEL_ID,
    base_url: Runner::DIRECT_OUTBOUND_API_PROVIDERS.fetch(OPENROUTER_PROVIDER_KEY).fetch(:base_url),
    api_key_env: "OPENROUTER_API_KEY",
    provider_routing: build_provider_routing(@project)
  }
)
```

Pareto manages no tier IDs and exposes no tier configuration — it always ships `openrouter/pareto-code`. This justifies D3 ("Pareto is an ordinary catalog row, not a policy value"): promoting it from `model_policy: "pareto"` to a plain catalog entry removes the special-casing without changing runtime behavior.

### Provider slug equals `api_service_type` for every supported entry

Every entry in `Runner::DIRECT_OUTBOUND_API_PROVIDERS` and `Runner::PI_API_PROVIDERS` carries a `:service_type` that equals the provider slug (or matches the key the user sees). Examples:

| Provider slug | `:service_type` | Notes |
|---|---|---|
| `openrouter` | `openrouter` | D4 evidence |
| `anthropic` | `anthropic` | D4 evidence |
| `openai` | `openai` | D4 evidence |
| `inception` | `inception` | D4 evidence |
| `deepseek` | `deepseek` | D4 evidence |
| `mistral` | `mistral` | D4 evidence |
| `minimax` | `minimax` | env_var overridden to `ANTHROPIC_API_KEY` — service type still equals slug |
| `xai` | `xai` | D4 evidence |
| `zai` | `zai` | D4 evidence |
| `zai_coding` | `zai_coding` | D4 evidence |

Therefore, given a chosen `ProviderApiKey#api_service_type`, the provider slug is fixed. Asking the user to confirm a provider they already implied by the key is restating a fact the system already knows. Evidence for D4.

### Catalog coverage today vs. needed for a full dropdown

- **Seeded today:** `anthropic`, `openai`, `google`, `zai_coding`, `minimax` (`app/services/models/seed_known_models.rb:10`).
- **Empty today:** `deepseek`, `mistral`, `xai`, `zai`, `inception` — the dropdown would render empty for these providers without #3665.
- **OpenRouter free:** `catalog_source: "openrouter_sync"` (`app/services/free_models/sync.rb:88`).
- **Custom ids:** `catalog_source: "manual"` via `LlmModel.upsert_manual_catalog_entry`.

Evidence for "Dropdown without seed expansion" (Alternative 3 below).

### `catalog_source` semantics for the pareto row

If we promote Pareto to a plain catalog row, that row must be `catalog_source: "seeded"`, not `openrouter_sync`. `FreeModels::Sync#deactivate_missing_models!` (`app/services/free_models/sync.rb:116`) scopes to `LlmModel.openrouter_synced_free`, which is `free.openrouter_synced` (`app/models/llm_model.rb:37`). A `seeded` row is exempt from daily sync retirement. Evidence that the D3 catalog row must be `seeded` to survive daily syncs.

### RDR-040 `Runners::ModelCompatibility` is the established filtering layer

`Runners::ModelCompatibility.call` (`app/services/runners/model_compatibility.rb:49`) is the runner/model compatibility gate. It already powers `Runners::DefaultTierModelIds#runner_model_compatible?` (`app/services/runners/default_tier_model_ids.rb:54`), `Models::Select`, and `Models::DetectContractDrift`. The new dropdown reuses it rather than inventing a parallel gate.

### RDR-038 historical context

RDR-038 ("Alternative 4: Use Existing Runner Keys") explicitly rejected folding free-model selection into existing runners (`opencode`, `aider`, …) for discoverability reasons. RDR-065 does **not** reverse that decision — the catalog/rotation/governance machinery from RDR-038 is kept. RDR-065 only changes *how* the pseudo-keys appear in the UI, by:

- keeping them as addable runner rows (per RDR-038 discoverability),
- but flipping their model UX from "configure a tier list of free models" to "pick `model_policy: free` + tier, or pick a plain catalog row," with the same backing services.

## Decision

Adopt a **catalog-driven `<select>`** for the Model field on `opencode`, `kilocode`, `pi`, and `omp`, sourced from `LlmModel` filtered through `Runners::ModelCompatibility` (RDR-040) and the runner's `api_service_type`. Treat the pseudo-keys `openrouter_free` and `openrouter_pareto` as policy overlays on OpenCode rather than as independent runner CLIs.

The model selection UX resolves to four cases:

```
┌────────────────────────────────────────────────────────────────────────┐
│ Case 1: model_policy = "specific"                                       │
│   Source: LlmModel active, provider == selected api_service_type,       │
│           filtered through Runners::ModelCompatibility                   │
│   Persist: runner.tier_model_ids[<tier>] = <model_id>                   │
│                                                                        │
│ Case 2: model_policy = "free"                                           │
│   Source: LlmModel.openrouter_synced_free.active, filtered through      │
│           Runners::ModelCompatibility (RDR-038 catalog)                 │
│   Persist: runner.tier_model_ids[<tier>] = <free_model_id>;             │
│            same data shape as today (model_policy="free" is recorded    │
│            on the runner for D6 follow-up work)                         │
│                                                                        │
│ Case 3: Pareto (any OpenRouter-keyed runner)                            │
│   Source: LlmModel row "openrouter/pareto-code" (provider "openrouter", │
│           catalog_source "seeded") — single option surfaced whenever    │
│           the runner's api_service_type is "openrouter"                  │
│   Persist:                                                              │
│     - openrouter_pareto runner: tier_model_ids unchanged                 │
│       (ParetoExecutionPlan hardcodes the model id); model_policy =       │
│       "specific"                                                         │
│     - other OpenRouter-keyed runners (opencode, kilocode, pi, omp with  │
│       an OpenRouter key): tier_model_ids[<tier>] = "openrouter/pareto-  │
│       code"; model_policy = "specific"                                   │
│                                                                        │
│ Case 4: Custom model id                                                 │
│   Sentinel at the bottom of the dropdown reveals the current free-text  │
│   input. Saved id lands in LlmModel via upsert_manual_catalog_entry      │
│   with catalog_source: "manual" (today's behavior).                       │
│   Persist: runner.tier_model_ids[<tier>] = <model_id>                   │
└────────────────────────────────────────────────────────────────────────┘
```

`model_policy` is an enum on `runners` with exactly two values:

- `specific` — Case 1, Case 3, and Case 4. Default for new direct-outbound runners.
- `free` — Case 2. Valid only for the `openrouter_free` runner today (post-closeout: the policy will port to other OpenRouter-keyed runners in #3673, but only when the `runner_model_policy_form` flag is on).

Ship behind `runner_model_policy_form`. The RDR closes out through #3672
after #3671 flips and removes the rollout flag.

## Goals

- Eliminate the free-text model UX on `opencode`, `kilocode`, `pi`, `omp` for the common case by surfacing catalog entries as a dropdown.
- Keep the free-text "Custom model ID…" escape hatch for users ahead of seed updates.
- Derive `api_provider` from the chosen `ProviderApiKey#api_service_type` so the two controls cannot drift.
- Treat `openrouter_free` and `openrouter_pareto` as model policies on OpenCode, not as separate runner CLIs.
- Reuse `Runners::ModelCompatibility` (RDR-040) so compatibility-gated filtering is uniform across the form, selection, and dispatch paths.
- Ship behind a feature flag so legacy `runner_key` keys keep executing until cutover.

## Non-Goals

- Do not build a "request a model" affordance. The free-text "Custom model ID…" sentinel and the `LlmModel.upsert_manual_catalog_entry` freshness escape hatch are sufficient (D1).
- Do not change subscription runners (`claude`, `codex`, `gemini`, `copilot`, `cursor`). They remain unchanged in this RDR (D5).
- Do not port the `model_policy: "free"` policy to Pi/OMP/KiloCode in this RDR. That port is #3673, an explicit non-blocker (D6).
- Do not introduce a new compatibility gate. The dropdown reuses `Runners::ModelCompatibility` (RDR-040).
- Do not change RDR-038's catalog/rotation/governance machinery. RDR-065 only supersedes the pseudo-key presentation; the data model and rotation logic stay.

## Proposed Solution

### Target Form UX

The dropdown contents below are split per runner key because the Free sentinel is only available on `openrouter_free` today (D6). An ordinary `opencode` runner with an OpenRouter key does **not** show the Free sentinel — that is reserved for the dedicated `openrouter_free` runner until #3673 ports the policy to other OpenRouter-keyed runners.

**`openrouter_free` runner** (Free policy is valid here today):

```
Runner:    [OpenRouter Free ▾]              ← dedicated runner row (RDR-038)
API Key:   [OpenRouter keys only ▾]         ← filtered to OpenRouter keys
Model:     [OpenRouter Free (curated, tiered)]  ← model_policy=free → tier picker
           [openrouter/pareto-code]              ← ordinary catalog row
           [ …synced free models …]              ← LlmModel.openrouter_synced_free, filtered
           [Custom model ID…]                   ← reveals text input
```

**`opencode` / `kilocode` / `pi` / `omp` with an OpenRouter key** (Free sentinel not shown today):

```
Runner:    [OpenCode CLI ▾]                ← pure CLIs; no Free/Pareto entries
API Key:   [OpenRouter keys grouped under "openrouter" ▾]
Model:     [openrouter/pareto-code]              ← ordinary catalog row (D3)
           [ …paid OpenRouter catalog rows… ]     ← provider == "openrouter"
           [Custom model ID…]                    ← reveals text input
```

**`opencode` / `kilocode` / `pi` / `omp` with a non-OpenRouter key** (no Pareto, no Free):

```
Runner:    [OpenCode CLI ▾]                ← pure CLIs; no Free/Pareto entries
API Key:   [Anthropic / OpenAI / … grouped ▾]
Model:     [ …catalog rows for provider == api_service_type … ]
           [Custom model ID…]                    ← reveals text input
```

For the `openrouter_free` runner, the model selector surfaces:

1. A pinned "OpenRouter Free (curated, tiered)" entry that persists `model_policy: "free"` and reuses today's tier-mapping form (RDR-038). This is the **Free** special entry (D2).
2. The `openrouter/pareto-code` row as an ordinary catalog entry (D3).
3. All other synced free models filtered through `Runners::ModelCompatibility`.
4. The "Custom model ID…" sentinel at the bottom.

For `opencode`, `kilocode`, `pi`, `omp`:

1. Catalog rows from `LlmModel.active` filtered to `provider == api_service_type`, then through `Runners::ModelCompatibility`.
2. The "Custom model ID…" sentinel at the bottom.

### Data Model

#### `runners.model_policy`

Add a `model_policy` column with values `specific` (default) and `free`:

```ruby
# Migration (backwards compatible: default "specific", null: false after backfill)
add_column :runners, :model_policy, :string, limit: 20, default: "specific", null: false,
  comment: <<~TEXT.squish
    How model selection is interpreted for this runner. "specific" means
    tier_model_ids point at named LlmModel rows; "free" means tier_model_ids
    are filled by FreeModels::DefaultTierModels via the openrouter_free runner
    (RDR-038). Other direct-outbound runners may adopt "free" post-closeout (#3673).
  TEXT
add_check_constraint :runners,
  "model_policy IN ('specific', 'free')",
  name: "runners_model_policy_enum"
```

Existing rows backfill to `"specific"`, except `openrouter_free` rows which backfill to `"free"` per the data migration step (see "Data Migration" below and the uniqueness/dispatch consistency requirement above). The free-policy port to Pi/OMP/KiloCode is a post-closeout follow-up (#3673, D6).

#### Free-policy uniqueness moves from runner-key to (user, OpenRouter key)

Today, `Runner.single_instance_runner_key?` returns `true` only for `openrouter_free`. This was paired with the "one free runner per user" gate that powers free-model rotation.

The new shape keeps the *intent* (one free-policy runner per user per OpenRouter key) but moves the gate from the runner key to the (user, provider_api_key) pair, so future free-policy ports don't need to re-introduce single-instance flags for each runner key.

```ruby
# Pseudo-shape (issue #3670 owns the migration)
def self.single_free_policy_per_openrouter_key?(user_id:, provider_api_key_id:)
  Runner.kept.where(user_id: user_id, model_policy: "free", provider_api_key_id: provider_api_key_id)
    .count <= 1
end
```

`Runner.single_instance_runner_key?` becomes deprecated for new code paths; the migration preserves existing `runner:<id>` identifiers while moving the free-runner uniqueness gate to the `(user, provider_api_key_id)` pair.

### `Runners::ModelOptions` (#3666)

A new service `Runners::ModelOptions` returns the dropdown source for a given (runner_key, api_service_type, runner, project) tuple. Single entry point for the form, the API, and the dispatch-side reconciliation:

```ruby
module Runners
  class ModelOptions
    def self.call(...)
      new(...).call
    end

    def initialize(runner_key:, api_service_type:, runner: nil, project: nil)
      @runner_key = runner_key.to_s
      @api_service_type = api_service_type.to_s
      @runner = runner
      @project = project
    end

    Result = Struct.new(:options, :free_policy_supported?, :pareto_supported?, keyword_init: true)

    def call
      # Returns array of { value:, label:, group:, free_policy:, pareto?: } hashes.
      # - For openrouter_free: prepends { free_policy: true, label: "OpenRouter Free (curated, tiered)" }.
      #                      pareto_supported? is true.
      # - For all OpenRouter-keyed runners (api_service_type == "openrouter"): prepends
      #                      { pareto?: true, label: "openrouter/pareto-code" } before the catalog rows.
      #                      pareto_supported? is true; free_policy_supported? is true only for openrouter_free.
      # - For all others: catalog rows for provider == api_service_type filtered through
      #                   Runners::ModelCompatibility. free_policy_supported? and pareto_supported? are false.
      # - Always appends { sentinel: "custom", label: "Custom model ID…" }
    end
  end
end
```

`Runners::ModelOptions` is the single source of truth the form selects from and the dispatch path cross-checks against.

### Key-Derived `api_provider` (#3667)

The form binds `runner[provider_api_key_id]` to a single API key, and `api_provider` is derived from `provider_api_key.api_service_type`:

```ruby
# New derivation (form-side; service-side accessor still available)
def runner_api_provider
  return nil unless provider_api_key
  Runner.api_service_type_to_provider_key(provider_api_key.api_service_type)
end
```

The reverse map `Runner::DIRECT_OUTBOUND_API_PROVIDERS` keyed by `:service_type` is the only new lookup; existing direct-outbound helpers (`opencode_api_provider`, etc.) keep working unchanged because they already look up `DIRECT_OUTBOUND_API_PROVIDERS[slug]` to compute `service_type`.

Form UX: the API Provider `<select>` is removed; the API Key `<select>` (today's free-text or dropdown) becomes the only key-side control. The Key dropdown groups keys by `api_service_type` (provider slug) so users see "Anthropic → claude-sonnet key" rather than a flat list.

### `model_policy` UI / dispatch (#3668)

`Runners::ResolveTierModel` and `Models::Select` consume `runner.model_policy`:

- `"specific"` (default): today's behavior — resolve `runner.tier_model_ids[tier]` or fallback to `Runners::DefaultTierModelIds`.
- `"free"`: today's behavior — `FreeModels::DefaultTierModels.call` for OpenRouter key + tier. The policy value is *informational* today; it becomes load-bearing when #3673 ports the policy to other OpenRouter-keyed runners.

`model_policy: "free"` is set only on `openrouter_free` rows in this RDR (D6).

### Form (#3669)

The form (`app/views/runners/_form.html.erb`) for direct-outbound runners becomes:

1. **Runner key** (existing control): unchanged. The "Add Runner" index page still offers `openrouter_free` and `openrouter_pareto` as separate addable rows for discoverability.
2. **API Key** dropdown, grouped by provider slug (D4).
3. **Model** dropdown populated from `Runners::ModelOptions` (D1). The trailing "Custom model ID…" sentinel reveals the current free-text input.

For `openrouter_free`:

1. **Runner key**: `OpenRouter Free` row (unchanged from RDR-038).
2. **API Key** dropdown, filtered to OpenRouter keys.
3. **Model** dropdown with the Free sentinel at the top (D2), `openrouter/pareto-code` (D3), other free models, and the custom sentinel.

For `openrouter_pareto`:

1. **Runner key**: `OpenRouter Pareto` row (unchanged from RDR-038).
2. **API Key** dropdown, filtered to OpenRouter keys.
3. **Model** dropdown shows `openrouter/pareto-code` only (D3) plus the custom sentinel.

Subscription runners are unchanged (D5).

### Data Migration (#3670)

The migration runs before the rollout guard is enabled in production:

1. Backfill `model_policy` to `"specific"` for all existing rows except `openrouter_free` (see step 2).
2. For each `openrouter_free` row: set `model_policy = "free"` so the new uniqueness scope `(user, provider_api_key_id)` and the new dispatch read the migrated rows consistently with the rest of this RDR. Leaving these rows at `model_policy = "specific"` would exclude them from the new free-policy invariants and let duplicate free-policy runners slip past the uniqueness check. Today's `FreeModels::DefaultTierModels` defaults continue to populate `tier_model_ids` via `sync_direct_outbound_tier_models`; the Free sentinel in the new form reuses the same defaults and does not change the persisted tier mapping.
3. Create the `LlmModel` row for `openrouter/pareto-code` with `provider: "openrouter"`, `catalog_source: "seeded"` (D3 evidence above — must be `seeded` to survive daily syncs).
4. Validate that every existing `Runner` row continues to execute under the new form. The dispatch path is backwards-compatible: legacy `tier_model_ids` continue to drive selection.

## Rollout Guard

- **Flag**: `runner_model_policy_form`
- **Default**: off
- **Enablement surface**: per-tenant opt-in via `tenant_settings.features`; planned enablement for the development tenant, then a percentage-of-actors rollout once telemetry confirms parity with the legacy form.
- **Rollback**: disable the flag; legacy form and legacy dispatch paths continue to render and execute unchanged. No data shape change is required to roll back.
- **Implementation issue**: #3669 must add the flag definition to `app/services/feature_flags.rb` and wire every runtime decision through `FeatureFlags.enabled?(:runner_model_policy_form, project:)` or the account-equivalent gate selected during implementation.
- **Cleanup criteria**: remove the flag once the new form has been the default for at least one billing period, the parity metrics (`broken_runner_models` occurrences, `runner_settings_invalid` failures, support tickets about model ids) match or improve vs. legacy, and the data migration (#3670) has been verified against a recent production snapshot.

## Alternatives Considered

### Alternative 1: Labels-Only Fix

Group the Runner dropdown so `openrouter_free` reads as `OpenCode — OpenRouter Free` and `openrouter_pareto` reads as `OpenCode — OpenRouter Pareto`. Zero backend change, fixes discoverability only; leaves the model-validation gap and the conceptual inversion.

**Rejected as the solution** because the UX failures in #3663 require more than discoverability. **Acceptable as an interim** if a quick wins-only release ships before this RDR.

### Alternative 2: Keep Pseudo-keys, Add Dropdown Only

Retain `openrouter_free` and `openrouter_pareto` as distinct runner keys; add the catalog dropdown only to `opencode`, `kilocode`, `pi`, `omp`. The two pseudo-keys keep their existing special-casing across ~10 code sites (egress unset-vars, single-instance checks, rotation keying, health checks, default-tier maps).

**Rejected.** The migration preserves row IDs (the runner rows are renamed in place via the existing `Runner` table), so the cost of folding the pseudo-keys into OpenCode is one-time and bounded. The gain is removing the conceptual inversion (D3) and the `model_policy` enum becoming a single source of truth across all direct-outbound runners.

### Alternative 3: Dropdown Without Seed Expansion

Ship the catalog dropdown without expanding `Models::SeedKnownModels::KNOWN_MODELS` to cover `deepseek`, `mistral`, `xai`, `zai`, `inception`. Five providers would render an empty dropdown.

**Rejected.** #3665 closes the seed gap as part of this issue tree; the dropdown ships with full coverage or not at all.

### Alternative 4: Pareto as a Third `model_policy` Value

Add `model_policy: "pareto"` as a third value (alongside `specific` and `free`).

**Rejected for simplicity (D3).** Promoting `openrouter/pareto-code` to an ordinary seeded catalog row achieves the same UX outcome with one fewer policy value to maintain. The Pareto runner continues to behave identically at dispatch because `Runners::ParetoExecutionPlan` already hardcodes the model id.

### Alternative 5: Retain the Provider Select Alongside the Key Dropdown

Keep the `api_provider` select as a confirmation step.

**Rejected (D4).** For every entry in `Runner::DIRECT_OUTBOUND_API_PROVIDERS` and `Runner::PI_API_PROVIDERS`, the provider slug equals the `:service_type`, which is what `ProviderApiKey#api_service_type` carries. The two controls encode the same fact and can disagree; the simpler design lets the key dropdown drive both.

## Trade-offs and Consequences

### Positive

- **Discoverability.** Users see a finite catalog list per provider rather than guessing model ids.
- **Validation at save time.** `Runners::ModelCompatibility` (RDR-040) gates the dropdown, so a user cannot save a model id that the runner CLI rejects — `direct_outbound_config_models_must_exist_in_catalog` and friends become stricter by construction.
- **Conceptual cleanup.** `openrouter_free` and `openrouter_pareto` are reframed as model policies on OpenCode; the `model_policy` enum documents the model-resolution contract for every direct-outbound runner.
- **Single compatibility gate.** All filtering funnels through `Runners::ModelCompatibility`, so the form, the selector, and the dispatch path see the same set of allowed models.
- **Escape hatch preserved.** The "Custom model ID…" sentinel keeps the freshness escape hatch via `LlmModel.upsert_manual_catalog_entry`; users ahead of seed updates are not blocked.

### Negative

- **Migration cost.** `model_policy` is a new column with a default backfill and a data migration (#3670); the form reroute touches views, controllers, and one new service (`Runners::ModelOptions`).
- **Empty dropdowns for unseeded providers** if #3665 is not shipped first. Acceptable because the issue tree orders them strictly.
- **`Runners::ModelOptions` becomes a small new gate.** Future selection work must remember to consult it (or `Runners::ModelCompatibility`) rather than going straight to `LlmModel`.
- **Pareto becomes an ordinary catalog row.** A user could in principle type "openrouter/pareto-code" as a custom id on an `opencode` runner; the existing Pareto runner remains the preferred entry point, but the dropdown opens a parallel path that today's `Runners::ParetoExecutionPlan` is the only consumer of.
- **Free-policy uniqueness moves from runner-key to (user, key).** Any code that keyed off `single_instance_runner_key?("openrouter_free")` must update; the migration covers this.

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Catalog is missing a model the user needs | Medium — user is blocked from saving | "Custom model ID…" sentinel + `upsert_manual_catalog_entry` are the documented escape hatch; the broken-runner-model detector still self-heals bad ids over time |
| `Runners::ModelCompatibility` returns `unknown` for a model we display | Low — confusing UX | The dropdown shows "may not be supported by installed CLI" copy next to `unknown` results; telemetry catches sustained misses |
| Migration leaves a runner with no compatible model | High — runner stops executing | Migration runs validation against the same `Runners::ModelCompatibility` gate the form uses; runners without a compatible row keep their existing `tier_model_ids` and execute via legacy path |
| `runner_model_policy_form` flag is on for one tenant but `model_policy: "free"` rows exist elsewhere | Low — feature-flag isolation | The flag is keyed per tenant; only tenants with the flag on see the new form. Migrated `openrouter_free` rows carry `model_policy: "free"` everywhere, but flag-off tenants continue to render the legacy form, which only displays the Free policy via the legacy `tier_model_ids` defaults — so the flag is the sole visibility gate. |
| Existing single-instance gate on `openrouter_free` breaks after migration | Medium — duplicate free runners allowed | Migration preserves the "one free-policy runner per user per OpenRouter key" invariant via the new check constraint / scope while keeping existing `runner:<id>` identifiers stable |

## Implementation Plan

The implementation mirrors the issue tree under #3663. Each phase is a separate issue with explicit dependencies.

1. **#3664 (this RDR)** — Author RDR-065, reviewed during planning, locked at implementation, closeout-audited by #3672.

2. **#3665** — Provider catalog seed gap. Expand `Models::SeedKnownModels::KNOWN_MODELS` to cover `deepseek`, `mistral`, `xai`, `zai`, `inception`; verify seed runs cleanly against a fresh database.

3. **#3666** — Add `Runners::ModelOptions`. Single entry point that returns the dropdown source for a (runner_key, api_service_type) pair. Filter through `Runners::ModelCompatibility` (RDR-040).

4. **#3667** — Derive `api_provider` from the chosen key. Add the key-grouping in the form; remove the API Provider `<select>` for direct-outbound runners. Add `Runner.api_service_type_to_provider_key`.

5. **#3668** — Add `runners.model_policy` column. Backfill to `"specific"`. Add the check constraint. Wire `Runners::ResolveTierModel` and `Models::Select` to consume the policy (informational for now; load-bearing for the #3673 port).

6. **#3669** — Form change + feature flag. Add `:runner_model_policy_form` to `FeatureFlags::DEFINITIONS`. Wire the runtime decision through `FeatureFlags.enabled?(:runner_model_policy_form, project:)`. Form uses `Runners::ModelOptions` for the Model dropdown. The trailing "Custom model ID…" sentinel reveals the free-text input. Tests cover the flag-off (legacy form), flag-on (new form), and key-grouping flows.

7. **#3670** — Data migration. Create the `LlmModel` row for `openrouter/pareto-code` with `catalog_source: "seeded"`. Backfill `model_policy`: default to `"specific"` for all rows, then set `openrouter_free` rows to `"free"` so the new uniqueness scope `(user, provider_api_key_id)` and the new dispatch read them consistently. Preserve row IDs and `runner:<id>` identifiers. Move single-instance uniqueness from runner-key to (user, provider_api_key_id).

8. **#3671** — Flip the flag, validate telemetry, and clean up the flag.

9. **#3672** — RDR-065 closeout audit. Verify each acceptance criterion against shipped code; update the RDR's `## Implementation Status` and the `docs/rdrs/README.md` index status.

10. **#3673** — Post-closeout follow-up: port `model_policy: "free"` to Pi/OMP/KiloCode. Explicit non-blocker for #3672. Issue filed but does not gate the closeout.

## Validation

### Walkthroughs

- **`opencode` + OpenRouter key → Pareto / paid / custom (no Free sentinel).**
  - Save a new `opencode` runner with an OpenRouter API key.
  - Model dropdown shows `openrouter/pareto-code`, paid OpenRouter catalog rows, and the "Custom model ID…" sentinel. The Free sentinel is **not** present — `model_policy: "free"` is only valid on `openrouter_free` today (D6).
  - Picking `openrouter/pareto-code` behaves like any specific catalog row: `model_policy = "specific"` is set and the model id is persisted to `tier_model_ids[<tier>]`.
  - Picking a paid OpenRouter catalog row sets `model_policy = "specific"` and persists the model id.
  - Picking "Custom model ID…" reveals the free-text input; saving with `moonshotai/kimi-k2.6` upserts an `LlmModel` row with `catalog_source: "manual"`.

- **`openrouter_free` runner → Free sentinel / Pareto / synced free models / custom.**
  - Save a new `openrouter_free` runner with an OpenRouter API key.
  - Model dropdown shows the Free sentinel at the top, `openrouter/pareto-code`, other synced free models filtered through `Runners::ModelCompatibility`, and the "Custom model ID…" sentinel.
  - Picking the Free sentinel sets `model_policy = "free"`, persists today's `FreeModels::DefaultTierModels` defaults to `tier_model_ids`, and renders the existing tier-mapping sub-form (RDR-038).
  - Picking `openrouter/pareto-code` sets `model_policy = "specific"` (ParetoExecutionPlan hardcodes the model id; `tier_model_ids` is unchanged).
  - Picking a synced free model sets `model_policy = "free"` and persists the model id like today.
  - Picking "Custom model ID…" reveals the free-text input; saving with `moonshotai/kimi-k2.6` upserts an `LlmModel` row with `catalog_source: "manual"`.

- **Anthropic key → Opus/Sonnet/Haiku only.**
  - Save a new `opencode` runner with an Anthropic API key.
  - Model dropdown shows only Anthropic catalog rows (filtered by `api_service_type == "anthropic"`) plus the "Custom model ID…" sentinel.
  - Saving an unsupported model id (e.g. `gpt-5.1`) is rejected by `Runners::ModelCompatibility`.

- **z.ai Coding Plan → glm-only.**
  - Save a new `opencode` runner with a `zai_coding` API key.
  - Model dropdown shows only the `zai_coding` catalog rows; users can fall back to custom for `glm-5.x` model ids the snapshot has not caught up with.

- **Subscription runners byte-identical.**
  - The Claude / Codex / Gemini / Copilot / Cursor form is unchanged; the new feature flag does not touch subscription runners.

- **Migrated runners preserve `runner:<id>` identifiers.**
  - Existing `AgentRun#runners_attempted` and `Provider` references continue to resolve via `Runner.routing_key` and `Runner.for_identifier` after the data migration.

### Tests

- `Runners::ModelOptions` returns catalog rows filtered by `api_service_type` and gated by `Runners::ModelCompatibility`.
- `Runners::ModelOptions` prepends the Free sentinel for `openrouter_free` and **omits it** for `opencode`/`kilocode`/`pi`/`omp` even when the selected key is an OpenRouter key (D6).
- `Runners::ModelOptions` includes `openrouter/pareto-code` for any runner whose `api_service_type` is `openrouter`.
- Key dropdown groups by `api_service_type` (provider slug).
- `Runners::ResolveTierModel` honors `model_policy: "free"` by delegating to `FreeModels::DefaultTierModels`.
- `Models::Select` consults `model_policy` before falling back to the global pool.
- Feature-flag-off: legacy form renders, legacy dispatch path executes unchanged.
- Feature-flag-on: new form renders, dispatch path executes the new dropdown values.
- `LlmModel.upsert_manual_catalog_entry` continues to be the persistence path for "Custom model ID…" inputs (regression test).
- Data migration backfills `openrouter_free` rows to `model_policy: "free"` and is idempotent; preserved row IDs are verified.

### Operational Checks

- Telemetry: parity of `Models::DetectBrokenRunnerModels` findings (`runner_settings_invalid`, `runner_model_not_found`) vs. the pre-rollout baseline.
- Dashboard: free-policy runner counts match the pre-migration single-instance gate.
- `FeatureFlags.enabled?(:runner_model_policy_form, project:)` returns the expected value for each tenant.

## Open Questions

1. **Sentinel copy localization.** The "Custom model ID…" label is currently English-only. Acceptable for v1 because the runner form is admin-facing; revisit if user-facing.
2. **Resolved — Pareto scope.** Case 3 above decides the scope: `Runners::ModelOptions` surfaces the `openrouter/pareto-code` seeded row whenever the runner's `api_service_type` is `openrouter` (openrouter_free, openrouter_pareto, or opencode/kilocode/pi/omp with an OpenRouter key). The dedicated `openrouter_pareto` runner row remains in the "Add Runner" index for discoverability (RDR-038). The dispatch side stays unchanged: the `openrouter_pareto` runner still routes through `Runners::ParetoExecutionPlan`; on other runners, selecting Pareto persists the model id like any other specific catalog row.
3. **Does `model_policy: "free"` need its own rotation keying?** Today rotation is keyed on `runner:<id>`; the #3673 port will need to revisit this if a single (user, key) pair can back multiple free-policy runners in the future.
