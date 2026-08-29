# RDR-038: Free Models Catalog and Runner

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-30
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: #2378 (tracking), #2381 (phase 1), #2380 (phase 2), #2379 (phase 3a), #2383 (phase 3b), #2382 (phase 3c), #2384 (phase 4), #2385 (phase 5), #3170 (closeout audit)
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md) (agent-harness), [RDR-008](RDR-008-model-selection.md) (model selection), [RDR-034](RDR-034-tier-based-runner-fallback.md) (tier-based fallback), [RDR-025a](RDR-025a-runner-quota-tracking.md) (runner quota tracking)

## Implementation Status

Implemented. Paid ships the full free-model catalog and runner flow described here: `LlmModel` free-model fields, project `data_classification`, OpenRouter data-routing controls, daily OpenRouter free-model sync, deterministic classification, quality-bar filtering, default tier selection, rotation for knowledge execution, catalog UI, exclusions, and runner wiring. The phase chain that originally tracked this work (#2378, #2381, #2380, #2379, #2383, #2382, #2384, #2385) is closed.

**Superseded (RDR-065, #3671):** the dedicated `openrouter_free` (and
`openrouter_pareto`) runner keys this RDR introduced no longer exist.
[RDR-065](RDR-065-runner-model-selection-ux.md) folded them into the
`opencode` runner as a `model_policy: "free"` config value (any
OpenRouter-keyed direct-outbound runner may now hold that policy); a data
migration converted every existing row in place, preserving `runner:<id>`
identifiers. The catalog, sync, classification, quality-bar, and rotation
machinery described below is unchanged and still the load-bearing
implementation — only the runner-key presentation moved.

## Closeout Audit (2026-08-04)

The closeout audit in [#3170](https://github.com/viamin/paid/issues/3170) verified
that the phase-2 gap previously called out here is shipped:

- `FreeModels::Sync` persists zero-priced OpenRouter models into `LlmModel` with
  `pricing_tier: "free"` and `catalog_source: "openrouter_sync"`, links paid
  counterparts, preserves upstream metadata, and deactivates disappeared synced
  rows.
- `FreeModels::Classify` derives capability score and tier from deterministic
  metadata heuristics.
- `FreeModels::QualityFilter` marks weak models with
  `metadata["below_quality_bar"]`.
- `FreeModels::SyncJob` is scheduled daily through GoodJob.
- `FreeModels::DefaultTierModels` and free-model rotation skip
  `below_quality_bar` models by default.

As a result, closed issue [#2380](https://github.com/viamin/paid/issues/2380)
should be treated as completed implementation work, not as an active gap.

## Problem Statement

Paid has no zero-cost entry path. Every agent run requires at least one configured API key for a paid LLM provider, and users who exhaust their paid-provider quotas have no safety net. Meanwhile, OpenRouter exposes 27 free models — several with 1M-token context windows, tool use, and reasoning capability — that are fully compatible with Paid's existing OpenRouter integration but are undiscoverable and ungated.

Three concrete gaps:

1. **No onboarding path without a credit card.** New users must configure an Anthropic, OpenAI, or Google API key (or have a tenant-managed credential) before their first agent run. There is no "try before you buy" experience.

2. **No always-available fallback.** When all paid runners are rate-limited or circuit-opened, agent runs fail hard. Users who configured fallback runners still lose if every runner in the chain is exhausted.

3. **No data-governance gating for model selection.** Some projects contain proprietary source code under NDAs; others are open-source. Free models may route to providers that train on user data. There is no mechanism to classify project sensitivity and gate model eligibility accordingly.

Requirements:

- Users with an OpenRouter API key can configure a runner that uses free models exclusively.
- The runner is a first-class citizen: usable as primary, fallback, or chat-only, with all standard runner configuration.
- Free models are organized into Paid's existing tier system (low/mid/high) and participate in the standard model-selection pipeline.
- Projects carry a data classification that gates which models are eligible. The classification maps to OpenRouter's per-request `data_collection` routing parameter.
- Users can opt out of specific free models and the catalog is curated to exclude models below Paid's quality bar.
- Free model availability is synced from the OpenRouter API, not hardcoded.

## Context

### Current Architecture

```
                          ┌──────────────────────────────────┐
                          │ Models::Select                   │
                          │  1. Project override / preferred  │
                          │  2. Quality escalation            │
                          │  3. Meta-agent or rules-based     │
                          │  → ModelSelection record          │
                          └──────────────┬───────────────────┘
                                         │
                          ┌──────────────▼───────────────────┐
                          │ Runners::ResolveTierModel         │
                          │  (runner, tier) → model_id        │
                          │  1. runner.tier_models[tier]      │
                          │  2. provider.tier_models[tier]    │
                          │  3. DefaultTierModelIds defaults  │
                          └──────────────┬───────────────────┘
                                         │
                          ┌──────────────▼───────────────────┐
                          │ Runner loop (fallback chain)      │
                          │  circuit breaker + rate-limit     │
                          │  tracking per RunnerState         │
                          └──────────────────────────────────┘
```

Key components:

- **`LlmModel`** — catalog of known models with `model_id`, `tier`, `capability_score`, `provider`, pricing columns. Seeded from RubyLLM registry via `Models::SeedKnownModels`. No concept of "free" models today.
- **`Runner`** — execution surface (Claude CLI, Codex CLI, OpenCode, etc.). Direct-outbound runners (`opencode`, `kicode`, `aider`, `pi`) support OpenRouter as an API provider via `ProviderApiKey` with `api_service_type: "openrouter"`.
- **`RunnerState`** — circuit breaker (closed/open/half_open) and rate-limit tracking per user+runner.
- **`Models::Select`** — model selection pipeline that picks a tier and model based on complexity, preferences, and runner configuration.
- **`Runners::ResolveTierModel`** — resolves `(runner, tier) → concrete model_id` at execution time.

### What Was Missing At Proposal Time

- `LlmModel` has no `pricing_tier` column — all models are implicitly paid.
- There is no scheduled job that syncs OpenRouter's free model catalog into `LlmModel`.
- There is no runner key specialized for free models. Users can manually configure an `opencode` runner with a free model ID, but there's no discovery, no curation, and no rotation.
- There is no `data_classification` on projects, and no mechanism to map project sensitivity to OpenRouter's routing parameters.
- There is no per-model rotation within a single runner on rate-limit errors. When a direct-outbound runner's model is rate-limited, the circuit breaker opens on the whole runner.

## Research Findings

### OpenRouter Free Model API

The `GET https://openrouter.ai/api/v1/models` endpoint returns 356 models (as of 2026-05-30). Each model object has 17 top-level fields:

| Field | Type | Relevance to Free Runner |
|-------|------|--------------------------|
| `id` | string | Free models have `:free` suffix (e.g., `deepseek/deepseek-v4-flash:free`) |
| `name` | string | Display name |
| `canonical_slug` | string | Version-pinned slug with date (e.g., `deepseek/deepseek-v4-flash-20260423`) |
| `hugging_face_id` | string or null | Open-weight indicator (170 of 356 set) |
| `context_length` | integer | Context window in tokens |
| `architecture.modality` | string | e.g., `text->text`, `text+image+video->text` |
| `architecture.input_modalities` | array | `["text", "image", "video", "audio", "file"]` |
| `architecture.output_modalities` | array | `["text", "image", "audio"]` |
| `pricing.prompt` | decimal string | Cost per prompt token — `"0"` for free models |
| `pricing.completion` | decimal string | Cost per completion token — `"0"` for free models |
| `top_provider.max_completion_tokens` | integer or null | Max output tokens |
| `top_provider.is_moderated` | boolean | Whether provider applies content moderation |
| `supported_parameters` | array | `["tools", "reasoning", "structured_outputs", ...]` |
| `knowledge_cutoff` | string or null | Training data cutoff date |
| `expiration_date` | string or null | When the model will be removed (10 of 356 set) |
| `links.details` | string | Path to per-endpoint API |

#### Free Model Detection

No `is_free` boolean exists. Free models are identified by:

```ruby
pricing["prompt"] == "0" && pricing["completion"] == "0"
```

This identifies 27 free models. 23 have the `:free` suffix on their `id`. 4 are zero-priced without the suffix (`google/lyria-3-clip-preview`, `google/lyria-3-pro-preview`, `openrouter/free`, `openrouter/owl-alpha`).

#### The 27 Free Models (2026-05-30 Snapshot)

**Tier S — 1M context, tools + reasoning, 100K+ output:**

| Model ID | Context | Max Output | Tools | Reasoning | Moderated |
|----------|---------|------------|-------|-----------|-----------|
| `deepseek/deepseek-v4-flash:free` | 1M | 384K | yes | yes | no |
| `nvidia/nemotron-3-super-120b-a12b:free` | 1M | 262K | yes | yes | no |
| `qwen/qwen3-coder:free` | 1M | 262K | yes | yes | no |

**Tier A — 262K+ context, tools + reasoning:**

| Model ID | Context | Max Output | Tools | Reasoning |
|----------|---------|------------|-------|-----------|
| `moonshotai/kimi-k2.6:free` | 262K | — | yes | yes |
| `google/gemma-4-31b-it:free` | 262K | 32K | yes | yes |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | 256K | 65K | yes | yes |
| `poolside/laguna-m.1:free` | 262K | 32K | yes | yes |
| `poolside/laguna-xs.2:free` | 262K | 32K | yes | yes |

**Tier B — 131K context, tools:**

| Model ID | Context | Max Output | Tools | Reasoning | Moderated |
|----------|---------|------------|-------|-----------|-----------|
| `openai/gpt-oss-120b:free` | 131K | 131K | yes | yes | yes |
| `openai/gpt-oss-20b:free` | 131K | 8K | yes | yes | yes |
| `meta-llama/llama-3.3-70b-instruct:free` | 131K | — | yes | no | no |
| `z-ai/glm-4.5-air:free` | 131K | 96K | yes | yes | no |
| `nvidia/nemotron-3-nano-30b-a3b:free` | 256K | — | yes | yes | no |
| `nvidia/nemotron-nano-12b-v2-vl:free` | 128K | 128K | yes | yes | no |
| `nvidia/nemotron-nano-9b-v2:free` | 128K | — | yes | yes | no |

**Tier C — smaller models, limited features:**

| Model ID | Context | Tools | Reasoning |
|----------|---------|-------|-----------|
| `google/gemma-4-26b-a4b-it:free` | 262K | yes | yes |
| `minimax/minimax-m2.5:free` | 204K | yes | yes |
| `meta-llama/llama-3.2-3b-instruct:free` | 131K | no | no |
| `nousresearch/hermes-3-llama-3.1-405b:free` | 131K | no | no |
| `liquid/lfm-2.5-1.2b-instruct:free` | 32K | no | no |
| `liquid/lfm-2.5-1.2b-thinking:free` | 32K | no | yes |
| `cognitivecomputations/dolphin-mistral-24b-venice-edition:free` | 32K | no | no |
| `openrouter/free` | 200K | yes | yes |
| `openrouter/owl-alpha` | 1M | yes | no |
| `google/lyria-3-clip-preview` | 1M | no | no |
| `google/lyria-3-pro-preview` | 1M | no | no |

#### Endpoint Sub-API

`GET /api/v1/models/{canonical_slug}/endpoints` returns per-provider routing data with:

- `provider_name`, `quantization`, `pricing`, `supported_parameters`
- `uptime_last_30m`, `uptime_last_5m`, `uptime_last_1d`
- `max_completion_tokens`, `supports_implicit_caching`

This data is useful for health monitoring but is not required for the initial implementation.

#### What the API Does NOT Expose

- **No `is_free` boolean** — must infer from pricing.
- **No per-model privacy/data-training fields** — OpenRouter manages this via per-request routing parameters, not per-model metadata.
- **No per-model rate limits** — OpenRouter applies rate limits server-side. Free model limits are per-account (across all free models), not per-model.
- **No latency/throughput in the models list** — available per-endpoint via the endpoints sub-API.

### OpenRouter Data Policy Controls

OpenRouter provides two per-request parameters for data governance:

#### `provider.data_collection`

| Value | Effect |
|-------|--------|
| `"allow"` (default) | Route to any provider, including those that may store data or train on it |
| `"deny"` | Only route to providers that do not collect user data non-transiently |

This is also available as an account-wide setting at `/settings/privacy`.

#### `provider.zdr` (Zero Data Retention)

| Value | Effect |
|-------|--------|
| `true` | Only route to endpoints with a Zero Data Retention policy |
| `false`/unset | No ZDR enforcement |

These parameters are the primary mechanism for enforcing data governance — not per-model curation. OpenRouter has first-party knowledge of each provider's policies and enforces routing at their layer.

### OpenRouter Rate Limits for Free Models

From OpenRouter's FAQ:

- **Without credits**: ~20 free model API requests per day (per account, across all free models).
- **With credits** (minimum purchase threshold): higher free model rate limit per day.
- Rate limits are per-account, not per-model. Rotating between free models does not circumvent the daily limit.
- OpenRouter may additionally apply per-provider rate limits.

For Paid's BYOK model, rate limits are on the user's OpenRouter account. Users who add credits to their OpenRouter account get higher limits.

## Proposed Solution

### Design Principle

Free models are not a special runner type — they are first-class entries in the `LlmModel` catalog, accessible through a dedicated `openrouter_free` runner that uses the user's own OpenRouter API key. The "free" aspect is a model attribute (`pricing_tier`), not a runner architectural concern. Users configure the runner like any other: primary, fallback, chat-only, with standard weights and priority.

### New `openrouter_free` Runner Key

A new direct-outbound runner key that:

- Appears as an addable runner **only** when the user has an OpenRouter `ProviderApiKey`.
- Uses OpenRouter's API directly (same base URL and auth as the existing `openrouter` provider config).
- Is pre-configured with curated free model tier mappings.
- Passes `provider.data_collection` based on the project's `data_classification`.
- Supports all standard runner configuration: `enabled_for_agent_runs`, `enabled_for_chat`, `enabled_for_fallback`, `fallback_role`, `weight`.
- Rotates to the next free model within the same tier on rate-limit errors, before falling back to a different runner.

### Data Model Changes

#### `llm_models` additions

```ruby
# Migration: add_free_model_support_to_llm_models
t.string  :pricing_tier,       default: "paid",    null: false
t.string  :data_training_risk,                      null: true   # "none" | "possible" | "unknown"
t.string  :catalog_source,     default: "seeded",  null: false  # "seeded" | "openrouter_sync" | "manual"
t.datetime :expires_at,                             null: true
t.bigint  :free_variant_of_id,                     null: true   # FK → llm_models (paid counterpart)

add_foreign_key :llm_models, :llm_models, column: :free_variant_of_id
```

- `pricing_tier` — `"paid"` (default), `"free"`, or `"freemium"`. Filters free models in the catalog.
- `data_training_risk` — UI indicator only. Defaults to `"possible"` for free models (conservative). Actual enforcement is via OpenRouter's `data_collection` routing parameter. `nil` for paid models (not applicable).
- `catalog_source` — tracks where the model record came from. `"openrouter_sync"` models are managed by the sync job; `"seeded"` models are managed by `SeedKnownModels`; `"manual"` models are user-created.
- `expires_at` — from OpenRouter's `expiration_date`. Used for alerts and filtering.
- `free_variant_of_id` — links a free model to its paid counterpart (e.g., `deepseek/deepseek-v4-flash:free` → `deepseek/deepseek-v4-flash`).

#### `projects` addition

```ruby
# Migration: add_data_classification_to_projects
t.string :data_classification, default: "internal", null: false
# Values: "open" | "internal" | "confidential" | "restricted"
```

Maps to OpenRouter routing parameters:

| Classification | `data_collection` | `zdr` | Effect |
|---|---|---|---|
| `open` | `"allow"` | `false` | All providers, including those that may train |
| `internal` | `"allow"` | `false` | All providers (default) |
| `confidential` | `"deny"` | `false` | Only non-collecting providers |
| `restricted` | `"deny"` | `true` | Non-collecting providers + Zero Data Retention |

### Free Model Sync Service

#### `FreeModels::Sync`

Scheduled GoodJob (daily) that:

1. Calls `GET https://openrouter.ai/api/v1/models`.
2. Identifies free models: `pricing["prompt"] == "0" && pricing["completion"] == "0"`.
3. For each free model:
   - Creates or updates `LlmModel` with:
     - `model_id` = OpenRouter `id` (e.g., `deepseek/deepseek-v4-flash:free`)
     - `display_name` = OpenRouter `name`
     - `provider` = prefix from `id` (e.g., `deepseek`)
     - `pricing_tier: "free"`, `catalog_source: "openrouter_sync"`
     - `data_training_risk: "possible"` (conservative default)
     - `context_window` = `context_length`
     - `max_output_tokens` = `top_provider.max_completion_tokens`
     - `supports_tools` = `"tools" in supported_parameters`
     - `supports_vision` = `"image" in architecture.input_modalities`
     - Capability score and tier from `FreeModels::Classify`
     - Full API response in `metadata` jsonb
   - Attempts to link to paid variant via `free_variant_of_id` (strip `:free` suffix, look up by `model_id`).
4. Marks models inactive when they disappear from the API response.
5. Sets `expires_at` from `expiration_date`.
6. Logs sync summary: `models_synced`, `new_models`, `removed_models`.

#### `FreeModels::Classify`

Heuristic that maps free models to Paid's existing `capability_score` (0-10) and `tier` (low/mid/high):

```
Base score:                    3.0
+ 1M+ context window:         +3.0
+ 256K-999K context window:   +2.0
+ 128K-255K context window:   +1.0
+ tools support:              +2.0
+ reasoning support:          +1.5
+ 100K+ max output:           +1.0
+ 32K-99K max output:         +0.5
+ multimodal (vision/video):  +1.0
```

Tier mapping:

| Score range | Tier |
|-------------|------|
| >= 8.0 | `high` |
| >= 6.0 | `mid` |
| < 6.0 | `low` |

This produces the same tier semantics as paid models, so `Models::Select` works unchanged.

#### Quality Filter

Not all 27 free models meet Paid's quality bar for the default experience. A curated constant defines the minimum criteria for models enabled by default:

```ruby
FREE_MODEL_MINIMUM_CRITERIA = {
  min_context_window: 128_000,
  requires_tools: true
}.freeze
```

Models that don't meet these criteria are synced but marked with `metadata["below_quality_bar"] = true`. They are excluded from the default tier mappings but users can opt in.

Users can also opt out of specific models via `project.model_preferences["excluded_free_model_ids"]`.

### Runner Implementation

#### Runner Key Registration

Add `"openrouter_free"` to:

- `Runner::RUNNER_KEYS` (or equivalent constant)
- `RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS`
- `Runner::DIRECT_OUTBOUND_API_PROVIDERS` — reuses existing `"openrouter"` provider config

The runner is a direct-outbound runner that uses the OpenRouter API directly, same as `opencode` or `aider` with an OpenRouter key.

#### `Runners::FreeModelExecutionPlan`

Builds the execution plan for the `openrouter_free` runner:

```ruby
module Runners
  class FreeModelExecutionPlan
    def call(runner:, model_id:, project:, **)
      provider_api_key = runner.provider_api_key
      raise "OpenRouter API key required" unless provider_api_key&.openrouter?

      config = {
        model: model_id,
        base_url: "https://openrouter.ai/api/v1",
        api_key_env: "OPENROUTER_API_KEY",
        provider_routing: build_provider_routing(project)
      }

      Result.new(config: config)
    end

    private

    def build_provider_routing(project)
      classification = project&.data_classification || "internal"

      case classification
      when "open", "internal"
        { data_collection: "allow" }
      when "confidential"
        { data_collection: "deny" }
      when "restricted"
        { data_collection: "deny", zdr: true }
      end
    end
  end
end
```

The `provider_routing` hash is passed to the OpenRouter API as the `provider` object in chat completion requests.

#### `FreeModels::Rotation`

When a free model returns a rate-limit error (HTTP 429), rotate to the next free model within the same tier:

1. Get the runner's configured tier model IDs (from `runner.tier_model_ids`).
2. Build a candidate list: all active `LlmModel` records with `pricing_tier: "free"`, same tier, not excluded by the user, not below the quality bar (unless opted in).
3. Order by `capability_score` descending.
4. Skip the current model (the one that was rate-limited).
5. Skip models with an active rate limit in `RunnerState` (keyed by `runner_name + model_id`).
6. If candidates remain, update the runner's current model and retry.
7. If no candidates in the tier, try the next tier down (high → mid → low).
8. If all exhausted, mark the runner as rate-limited and surface to the user.

This rotation is integrated into the existing fallback loop in `Knowledge::RunnerExecutor` — when the `openrouter_free` runner fails with a rate-limit error, it rotates the model within the runner rather than immediately falling back to a different runner.

#### Conditional Visibility

In `RunnersController#load_index_context`, `openrouter_free` only appears in `@addable_runner_options` when:

1. The user has a `ProviderApiKey` with `api_service_type: "openrouter"`.
2. The user does not already have an `openrouter_free` runner.

When a user adds an OpenRouter API key, the "Add Runner" page immediately shows `openrouter_free` as an option.

#### Pre-Configured Defaults

When an `openrouter_free` runner is created, it comes pre-populated with the best free model per tier:

```ruby
FREE_RUNNER_DEFAULT_TIER_MODELS = {
  "high" => "deepseek/deepseek-v4-flash:free",
  "mid"  => "deepseek/deepseek-v4-flash:free",
  "low"  => "nvidia/nemotron-nano-9b-v2:free"
}.freeze
```

(The specific model IDs are updated by the sync job and read from the `LlmModel` table at runner-creation time, not hardcoded at runtime.)

Default configuration suggestions:

- `fallback_role: "rate_limit_fallback"` — suggested use as a safety net for paid runners.
- `enabled_for_fallback: true` — automatically available when paid runners fail.
- `enabled_for_agent_runs: true` — usable as a primary runner too.
- `enabled_for_chat: true` — free models are useful for chat.

All defaults are suggestions the user can change.

### Privacy and Guardrails

#### Data Classification as the Gating Mechanism

The `data_classification` on projects is the single source of truth for data governance:

- **Project-level**: `project.data_classification` determines which OpenRouter routing parameters to use.
- **Request-level**: `Runners::FreeModelExecutionPlan` maps classification to `data_collection` and `zdr` parameters.
- **OpenRouter-level**: OpenRouter enforces the routing — only providers that match the requested policy receive the request.

This three-layer enforcement means:

- Paid does not need to maintain a per-model data-training-risk database. OpenRouter has first-party knowledge of each provider's policies.
- `data_training_risk` on `LlmModel` is a **UI indicator** to set user expectations, not an enforcement mechanism.
- The default of `"possible"` for all free models is conservative and honest — some free models may route to providers that train on data, but if the project is `confidential`/`restricted`, OpenRouter's routing prevents it.

#### `Guardrails::DataClassificationPolicy`

A guardrail that runs during model selection as a safety net:

- Checks that the selected model is compatible with the project's `data_classification`.
- For `confidential`/`restricted` projects: warns (but does not block) if a free model with `data_training_risk: "possible"` is selected and the runner is NOT `openrouter_free` (which would enforce `data_collection: "deny"`).
- Logs the classification decision to `OrchestrationDecision`.
- This is a safety net, not the primary enforcement — the primary enforcement is in `Runners::FreeModelExecutionPlan`.

#### Audit Trail

- `TokenUsage` records for free models include `pricing_tier: "free"` in `metadata`.
- `OrchestrationDecision` records include `data_classification` and `provider_data_collection` in `context`.
- Dashboard shows free model usage broken down by project classification.

## Alternatives Considered

### Alternative 1: Platform-Managed OpenRouter Key

**Description**: Paid provides a shared OpenRouter API key for free model access. Users get zero-config onboarding with no API key required.

**Pros**:

- True zero-config onboarding. No API key setup friction.
- Paid controls the rate-limit pool and can provision higher limits.
- Simpler UX — "click here to start for free."

**Cons**:

- Paid bears the infrastructure cost (even for free models, there are operational costs).
- Rate-limit pool is shared across all users — one heavy user degrades experience for everyone.
- Paid becomes responsible for OpenRouter account management, privacy settings, and compliance.
- Does not align with Paid's BYOK philosophy for provider credentials.

**Reason for rejection**: User decision. BYOK keeps Paid's operational footprint minimal and gives users direct control over their OpenRouter account, rate limits, and privacy settings. The trade-off is slightly more setup friction, which is mitigated by the pre-configured runner defaults.

### Alternative 2: Per-Model Data Training Risk Curation

**Description**: Maintain a curated database of which free models route to providers that train on data, based on manual research of each provider's TOS.

**Pros**:

- Fine-grained control over model eligibility per project.
- Can block specific models for sensitive projects without relying on OpenRouter's routing.

**Cons**:

- OpenRouter routes each model to multiple upstream providers (e.g., DeepSeek V4 Flash has 14 providers). The data-training risk depends on which provider is selected at routing time, not on the model itself.
- Provider policies change. Maintaining accurate per-model assessments is a continuous effort.
- OpenRouter already provides `data_collection: "deny"` which achieves the same goal with first-party data.

**Reason for rejection**: OpenRouter's `data_collection` parameter is more reliable than any third-party curation because OpenRouter has direct knowledge of each provider's policies and enforces routing in real-time. Per-model curation is still useful as a UI indicator (`data_training_risk`) but not as the enforcement mechanism.

### Alternative 3: Fallback-Only Runner

**Description**: The free models runner is only activated when all paid runners are rate-limited. It cannot be used as a primary runner.

**Pros**:

- Simpler mental model — free models are a safety net, not a primary tool.
- Less concern about data-training risk for routine use.

**Cons**:

- No onboarding path. New users still need a paid API key before their first run.
- Forecloses on the use case of open-source projects that have no budget for paid models.
- Contradicts the "treat like all other runners" principle.

**Reason for rejection**: User decision. The free models runner should be configurable as primary, fallback, or chat-only, giving users full control over how they use it.

### Alternative 4: Use Existing Runner Keys (No Dedicated Free Runner)

**Description**: Instead of a new `openrouter_free` runner key, let users configure existing runners (`opencode`, `aider`, etc.) with free model IDs from OpenRouter.

**Pros**:

- No new runner key to register, document, or maintain.
- Maximum flexibility — any runner can use free models.

**Cons**:

- No discoverability. Users must know that free models exist, find the model IDs, and manually configure them.
- No pre-configured defaults. Users must research which free models are good.
- No built-in model rotation or data-governance integration.
- No conditional visibility based on OpenRouter API key presence.

**Reason for rejection**: While technically possible, this provides no onboarding value and leaves all the hard problems (discovery, curation, rotation, governance) to the user. The dedicated runner key is a convenience layer that makes free models accessible.

## Trade-offs and Consequences

### Positive

- **Zero-cost onboarding path.** Users with an OpenRouter API key can run agent jobs without any paid provider.
- **Always-available fallback.** Free models are never rate-limited by Paid's paid providers (they use a separate API key and provider). When all paid runners are exhausted, the free runner is still available.
- **Privacy by default.** Project data classification maps directly to OpenRouter's routing controls. Sensitive projects automatically route to non-collecting providers.
- **Minimal architecture changes.** Free models slot into the existing `LlmModel` table and tier system. The `Models::Select` pipeline works unchanged. The runner uses existing direct-outbound infrastructure.
- **Self-maintaining catalog.** The sync job keeps the free model catalog current. New models appear automatically; expired models are deactivated.

### Negative

- **OpenRouter rate limits are low.** ~20 requests/day across all free models for accounts without credits. This limits free-model use to light workloads unless users add credits to their OpenRouter account.
- **Data-training optics.** Even with `data_collection: "deny"`, the perception of "free models might train on my code" may discourage adoption for sensitive projects. The `data_training_risk: "possible"` UI indicator reinforces this honestly.
- **Sync lag.** The catalog syncs daily. New free models appear within 24 hours; removed models may cause failed runs between syncs. The `expires_at` field mitigates this for models with known expiration dates.
- **Model quality variability.** Free models range from "comparable to mid-tier paid models" (DeepSeek V4 Flash) to "too limited for agent work" (1.2B parameter models). The quality filter addresses this, but users who opt into all models may have poor experiences with low-capability models.

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| OpenRouter changes or removes free model access | High — free runner becomes unusable | Sync job detects removal and deactivates models. User communication via dashboard. Runner health shows "no free models available." |
| Free model rate limits too restrictive for practical use | Medium — users hit limits quickly and get frustrated | Clear rate-limit messaging in UI. Suggestion to add OpenRouter credits. Rotation across models provides marginal improvement. |
| Data-training concern blocks enterprise adoption | Medium — enterprises avoid free models entirely | `data_collection: "deny"` + `zdr: true` for restricted projects. Clear UI documentation of the privacy controls. |
| Free model quality too low for agent runs | Medium — failed runs waste user time | Quality filter excludes sub-bar models by default. Users must opt into lower-quality models. Pre-configured defaults use only Tier S/A models. |
| OpenRouter API key management burden | Low — users must manage a separate credential | Streamlined setup flow. OpenRouter API keys are free to create. Pre-configured runner minimizes setup steps. |

## Implementation Plan

### Phase 1 — Data Model

**Issue**: #2381
**Dependencies**: None
**Files to create/modify**:

1. `db/migrate/TIMESTAMP_add_free_model_support_to_llm_models.rb` — add `pricing_tier`, `data_training_risk`, `catalog_source`, `expires_at`, `free_variant_of_id` to `llm_models`.
2. `db/migrate/TIMESTAMP_add_data_classification_to_projects.rb` — add `data_classification` to `projects`.
3. `app/models/llm_model.rb` — add validations, scopes (`free`, `paid`, `by_pricing_tier`), `free?` helper.
4. `app/models/project.rb` — add validation for `data_classification`, `confidential?` / `restricted?` helpers.
5. `db/schema.rb` — updated by migrations.

### Phase 2 — Free Model Sync and Classification

**Issue**: #2380
**Dependencies**: Phase 1 (#2381)
**Files to create/modify**:

1. `app/services/free_models/sync.rb` — sync service that calls OpenRouter API and upserts `LlmModel` records.
2. `app/services/free_models/classify.rb` — heuristic scoring and tier assignment.
3. `app/services/free_models/client.rb` — thin wrapper around OpenRouter models API (or use existing HTTP client).
4. `app/jobs/free_models/sync_job.rb` — scheduled GoodJob (daily).
5. `app/services/free_models/quality_filter.rb` — constant defining minimum quality criteria.
6. `config/initializers/free_models.rb` — schedule configuration (or GoodJob procfile entry).

### Phase 3a — Runner Key Registration and Execution Plan

**Issue**: #2379
**Dependencies**: Phase 1 (#2381)
**Files to create/modify**:

1. `app/models/runner.rb` — add `"openrouter_free"` to `RUNNER_KEYS`, `DIRECT_OUTBOUND_API_PROVIDERS`, configure as direct-outbound.
2. `lib/runner_support.rb` — add `"openrouter_free"` to `CONTAINER_EXECUTABLE_RUNNER_KEYS` and relevant constant sets.
3. `app/services/runners/free_model_execution_plan.rb` — builds execution config with `data_collection` and `zdr` parameters.
4. `app/services/runners/harness_execution_plan.rb` — route `openrouter_free` to `FreeModelExecutionPlan`.

### Phase 3b — Model Rotation and Conditional Visibility

**Issue**: #2383
**Dependencies**: Phase 2 (#2380), Phase 3a (#2379)
**Files to create/modify**:

1. `app/services/free_models/rotation.rb` — model rotation logic on rate-limit errors.
2. `app/models/runner_state.rb` — support per-model rate-limit tracking (extend key scheme or use metadata).
3. `app/controllers/runners_controller.rb` — conditional visibility in `load_index_context` and `load_runner_options`.
4. `app/services/knowledge/runner_executor.rb` — integrate rotation into fallback loop for `openrouter_free` runner.

### Phase 3c — Pre-Configured Defaults and Runner Form

**Issue**: #2382
**Dependencies**: Phase 3b (#2383)
**Files to create/modify**:

1. `app/services/free_models/default_tier_models.rb` — resolves best free model per tier from `LlmModel` table.
2. `app/models/runner.rb` — `ensure_free_runner_defaults` callback or method for pre-populating `tier_model_ids`.
3. `app/views/runners/_form.html.erb` — free-runner-specific form sections (data classification explanation, rate limit expectations).
4. `app/controllers/runners_controller.rb` — pre-populate defaults in `new` action for `openrouter_free`.

### Phase 4 — Data Classification Guardrails

**Issue**: #2384
**Dependencies**: Phase 1 (#2381), Phase 3a (#2379)
**Files to create/modify**:

1. `app/services/guardrails/data_classification_policy.rb` — guardrail that checks model eligibility against project classification.
2. `app/services/models/select.rb` — integrate `DataClassificationPolicy` into selection pipeline.
3. `app/services/token_usage_tracker.rb` — include `pricing_tier` in `TokenUsage` metadata.
4. `app/services/agent_runs/runner_selection_logger.rb` — include `data_classification` in `OrchestrationDecision` context.

### Phase 5 — Free Models Catalog UI and Onboarding

**Issue**: #2385
**Dependencies**: Phase 2 (#2380), Phase 3c (#2382), Phase 4 (#2384)
**Files to create/modify**:

1. `app/controllers/free_models_controller.rb` — catalog page controller.
2. `app/views/free_models/index.html.erb` — catalog page showing free models by tier.
3. `app/views/runners/index.html.erb` — "Free Models" badge and link to catalog.
4. `app/views/runners/_settings.html.erb` — free runner health section (models available, rate-limited).
5. `app/services/dashboard/runner_health.rb` — include free-model-specific health info.
6. `config/routes.rb` — add `resources :free_models, only: :index`.

## Validation

### Test Scenarios

1. **Free runner as primary**: User configures `openrouter_free` as primary runner with `mid` tier. Run selects `deepseek/deepseek-v4-flash:free`. Run succeeds with $0 cost. `TokenUsage` records `pricing_tier: "free"`.

2. **Free runner as fallback**: User has Claude (primary) and `openrouter_free` (fallback). Claude rate-limits. Fallback activates, selects `qwen/qwen3-coder:free` at `mid` tier. Run succeeds.

3. **Model rotation on rate limit**: `openrouter_free` uses `deepseek/deepseek-v4-flash:free`. Rate-limit error (429). Rotation selects `nvidia/nemotron-3-super-120b-a12b:free` (next `high`-tier free model). Retry succeeds.

4. **Data classification enforcement**: Project classified `confidential`. `openrouter_free` runner passes `data_collection: "deny"` to OpenRouter. OpenRouter routes to non-collecting providers only. Run succeeds.

5. **Restricted project with ZDR**: Project classified `restricted`. `openrouter_free` runner passes `data_collection: "deny"` and `zdr: true`. OpenRouter routes to ZDR-only endpoints. Run succeeds.

6. **Sync adds new free model**: Daily sync job runs. New model `vendor/new-model:free` appears in OpenRouter API. `FreeModels::Sync` creates `LlmModel` record with `pricing_tier: "free"`, `tier: "mid"`. Model appears in catalog.

7. **Sync removes expired model**: Daily sync job runs. `some/expiring-model:free` has `expiration_date: "2026-06-01"`. Job deactivates the model. Runner health shows "model expired."

8. **User opts out of specific model**: User adds `meta-llama/llama-3.3-70b-instruct:free` to `project.model_preferences["excluded_free_model_ids"]`. Model rotation skips it. Run uses next available model.

9. **No OpenRouter key**: User has no OpenRouter `ProviderApiKey`. `openrouter_free` does not appear in "Add Runner" options.

10. **All free models rate-limited**: All free models in the tier are rate-limited. Rotation exhausts candidates. Runner is marked rate-limited. Dashboard shows "Free runner rate-limited — all models exhausted." User is advised to add OpenRouter credits or wait for rate-limit reset.

### Performance

- Sync job runs daily (non-blocking). API call to OpenRouter ~1-2 seconds. Upsert of 27 models is fast.
- Model rotation adds one DB query (next candidate) per rate-limit event. This is on the error path, not the happy path.
- `data_classification` lookup is a single column read on an already-loaded project. No performance impact.

### Security

- OpenRouter API key stored via existing `ProviderApiKey` (encrypted `api_key` column).
- `data_classification` is enforced at the OpenRouter routing layer (not just in Paid's code). Even if Paid's guardrail has a bug, OpenRouter's `data_collection: "deny"` prevents data from reaching collecting providers.
- Free model sync does not expose any credentials — it reads from the public OpenRouter models API (no auth required for `GET /api/v1/models`).
- Per-model rate-limit tracking in `RunnerState` uses the same RLS and tenant scoping as existing runner state.

## Open Questions

1. **OpenRouter `:free` variant stability** — OpenRouter's free model catalog changes frequently (new models added, old ones removed). Should the sync job run more often than daily? Or should it run on-demand when a free model fails?

2. **Tier model ID updates** — When the sync job detects that a better free model exists for a tier, should it automatically update existing runners' `tier_model_ids`? Or should updates be manual? Lean manual, with a dashboard notification suggesting the update.

3. **Non-OpenRouter free models** — Some providers (Google, Cohere) offer free tiers directly. Should this architecture support non-OpenRouter free models? The `pricing_tier` column on `LlmModel` is provider-agnostic, but the runner key is OpenRouter-specific. Future work if needed.

4. **Account-level free runner provisioning** — Should tenant admins be able to provision an `openrouter_free` runner for all account members? This would use tenant-managed OpenRouter credentials. The existing `LlmCredentials::AccountResolver` pattern supports this.

## References

- [OpenRouter Models API](https://openrouter.ai/api/v1/models) — full model catalog
- [OpenRouter Provider Routing](https://openrouter.ai/docs/guides/routing/provider-selection) — `data_collection` and `zdr` parameters
- [OpenRouter FAQ — Rate Limits](https://openrouter.ai/docs/faq) — free model rate limit tiers
- [OpenRouter Privacy — Provider Logging](https://openrouter.ai/docs/guides/privacy/provider-logging) — provider data policies
- [RDR-007](RDR-007-agent-cli-abstraction.md) — agent-harness as the LLM interface
- [RDR-008](RDR-008-model-selection.md) — model selection strategy (free models extend, not replace)
- [RDR-034](RDR-034-tier-based-runner-fallback.md) — tier-based fallback (free models use the same tier resolution)
- [RDR-025a](RDR-025a-runner-quota-tracking.md) — runner state and circuit breaker
- [`app/models/runner.rb`](../../app/models/runner.rb) — runner model and direct-outbound provider config
- [`app/models/llm_model.rb`](../../app/models/llm_model.rb) — model catalog
- [`app/services/models/seed_known_models.rb`](../../app/services/models/seed_known_models.rb) — existing model seeding
- [`app/services/models/select.rb`](../../app/services/models/select.rb) — model selection pipeline
- [`app/services/runners/resolve_tier_model.rb`](../../app/services/runners/resolve_tier_model.rb) — tier→model resolution
