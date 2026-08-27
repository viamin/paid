---
parent: PAID
prefix: DIRECT-OUTBOUND-CATALOG
---

# Low-Level Design: Direct-Outbound Model Catalog Coverage

> Companion to the high-level design (`docs/high-level-design.md`). Tracks
> GitHub issue #3665 (RDR-065, 1/8), a prerequisite for the provider-filtered
> model dropdown built out under #3663.

## Context

`Runner::DIRECT_OUTBOUND_API_PROVIDERS` lists ten direct-outbound API
providers a runner can target. `Models::SeedKnownModels::KNOWN_MODELS` only
seeded catalog rows for five of them (`anthropic`, `openai`, `google`,
`zai_coding`, `minimax`); `deepseek`, `mistral`, `xai`, `zai`, and `inception`
had none. A model dropdown filtered by provider (`LlmModel.by_provider`)
renders empty for any provider with zero catalog rows, so those five
providers had no usable model selection UI.

Separately, `Runners::ParetoExecutionPlan` lets OpenRouter choose the actual
backing coding model per request server-side rather than Paid targeting a
fixed model id. That routing mode needs a catalog row (`model_id:
"openrouter/pareto-code"`) so the dropdown and tier/selection code have
something to list and resolve, even though the row does not describe a single
fixed model's real limits.

## Decision

### Catalog coverage

Add seed rows to `Models::SeedKnownModels::KNOWN_MODELS` for `deepseek`,
`mistral`, `xai`, `zai`, and `inception`, keyed so `LlmModel.provider` matches
the `service_type` each provider config declares in
`Runner::DIRECT_OUTBOUND_API_PROVIDERS`. `deepseek`, `mistral`, and `xai` are
in the RubyLLM registry that `Models::RegistryModels` fetches, so the merge in
`Models::SeedKnownModels.call` backfills current pricing/context/capability
fields over these snapshot values whenever the fetch succeeds. `zai` (the
direct pay-per-token z.ai API, distinct from the `zai_coding` flat-rate plan
already seeded) and `inception` are not in that registry, so their seed values
are conservative estimates pending published figures, same as the existing
`minimax` rows.

### Pareto row

Seed `openrouter/pareto-code` with `provider: "openrouter"`,
`catalog_source: "seeded"`, `pricing_tier: "paid"`. It is deliberately not
`catalog_source: "openrouter_sync"`: `FreeModels::Sync#deactivate_missing_models!`
only targets `LlmModel.openrouter_synced_free` (`catalog_source:
"openrouter_sync"` AND `pricing_tier: "free"`), so a `"seeded"` row is never a
candidate for daily deactivation regardless of what OpenRouter's free-model
list contains on a given day. `context_window`, `max_output_tokens`,
`capability_score`, and `tier` are conservative placeholders, not a real
ceiling — the actual backing model varies per request and is chosen upstream.

### Degradation contract

`LlmModel::CUSTOM_MODEL_OPTION` and `LlmModel.dropdown_options_for(provider)`
define the empty-provider behavior once, on the model catalog interface
itself, rather than leaving each dropdown-building call site to reinvent it:

- `dropdown_options_for` returns the active, provider-scoped catalog rows
  ordered for display (empty when the provider has no rows).
- Callers render `CUSTOM_MODEL_OPTION` alone when that relation is empty,
  instead of an empty `<select>`.

Issue #3663's `Runners::ModelOptions` (not yet built as of this segment) is
expected to consume this contract rather than re-deriving empty-provider
handling.

### Provider-derived runner model selection

Direct-outbound runner setup (`opencode`, `kilocode`, `pi`, `omp`) must not ask
the operator for both an API key and a second "API Provider" value that means
the same thing. For these runners, the selected `ProviderApiKey` is the source
of truth for the upstream provider because its `api_service_type` already
matches the allowed provider slug set.

The runner form therefore groups API key choices by `api_service_type`,
derives the effective provider from the selected key, and renders the model
dropdown from the active catalog rows for that derived service type via one
batched provider query, preserving the same provider-scoped option contract as
`LlmModel.dropdown_options_for(service_type)`. When the selected key changes,
the model options refresh to the new service type; the form no longer persists
`config[runner_key]["api_provider"]` for new saves.

Legacy `config[runner_key]["api_provider"]` values remain a fallback for
existing rows until the follow-up migration rewrites them, and the per-runner
default constants remain the final edge-case fallback when neither a selected
key nor a legacy config value exists.

### Drift detector interaction

`Models::DetectCatalogDrift::DEFAULT_PROVIDERS` (`anthropic`, `openai`,
`google`) is unchanged by this work. `deepseek`, `mistral`, and `xai` are in
RubyLLM's registry but are not added to `DEFAULT_PROVIDERS`: this seed catalog
is coverage for direct-outbound runner selection, not a set of providers Paid
resolves default-tier models for, so adding their rows must not start
generating deprecation drift findings against them.

## What this is not

- **Not a second source of truth for providers.** The provider dropdown is not
  authoritative for API-key direct-outbound runners anymore; the selected API
  key owns that fact.
- **Not a registry integration.** `zai` and `inception` seed values stay
  hand-maintained estimates until (if ever) RubyLLM's registry adds them.
