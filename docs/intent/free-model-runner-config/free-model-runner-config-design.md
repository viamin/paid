---
parent: PAID
prefix: FREE-MODEL-RUNNER
---

# Free Model Runner Configuration Design

## Context

Paid stores synced free models as first-class `LlmModel` rows and lets
direct-outbound runners (`opencode`, `kilocode`, `pi`, `omp`) opt into
`model_policy: "free"` (`Runner#free_model_policy?`) rather than exposing a
dedicated `openrouter_free` runner key — RDR-065 (#3671) migrated the
original dedicated key into that config-driven policy and removed it. What
is missing is the configuration experience for a free-policy runner: new
free-policy runners should start with sensible defaults, and the runner form
should explain the OpenRouter-specific tradeoffs instead of treating free
models like a generic flat model list.

This segment covers runner configuration only. Free-model sync, runtime
rotation, and request-time privacy routing stay in their existing segments and
services.

## Goals

- Resolve the default free model for each tier from live `LlmModel` rows rather
  than hardcoded IDs.
- Pre-populate a newly created free-policy runner with those tier mappings
  plus safe suggested flags, while preserving explicit user choices.
- Render a free-model-specific form section that:
  shows the current tier mappings,
  lets the user change them,
  groups eligible free models by tier,
  distinguishes below-quality-bar models,
  and explains OpenRouter routing and rate-limit expectations.

## Design

### `FreeModels::DefaultTierModels`

`FreeModels::DefaultTierModels` is the configuration-time resolver for the
free runner. It queries `LlmModel.openrouter_synced_free.active`, excludes rows
marked `metadata["below_quality_bar"] = true`, orders the remaining candidates
by descending `capability_score`, and returns the highest-capability model id
for each populated tier:

- `high`
- `mid`
- `low`

The service is mechanical and data-driven. It does not hardcode model ids or
encode runner behavior outside “pick the best catalog row per tier.”

### New-runner defaults

When a new runner is being created with `model_policy: "free"` set in its
submitted config (`Runner#free_model_policy?` true on the built record —
`RunnersController#apply_new_runner_defaults`):

- `tier_model_ids` defaults from `FreeModels::DefaultTierModels`
  (`Runner#sync_direct_outbound_tier_models`, model-level, not
  controller-level)
- `fallback_role` defaults to `"rate_limit_fallback"`
- `enabled_for_fallback`, `enabled_for_agent_runs`, and `enabled_for_chat`
  default to `true`

These are suggestions, not enforced policy. If the user already supplied a
value in the form, the defaulting path must leave that explicit choice intact.

### Free-runner form section

When the form is rendering a runner whose `model_policy` is `"free"` (any of
`opencode`/`kilocode`/`pi`/`omp`), it shows a dedicated “Free Model
Configuration” section instead of only the generic tier-mapping copy. The
section:

- renders the tier mapping selectors using only synced free models
- groups the selectable options by the model’s assigned tier
- appends a quality-bar indicator to each option label so weak catalog entries
  are visible but still selectable
- explains how project `data_classification` maps to OpenRouter routing:
  open/internal use standard routing, confidential uses
  `provider.data_collection: "deny"`, and restricted adds `provider.zdr: true`
- explains the expected free-model rate limit:
  about 20 requests per day without OpenRouter credits

The runner list and form both keep the “Free” affordance visible so users can
distinguish a free-policy runner from normal OpenRouter-backed
entries at a glance.
