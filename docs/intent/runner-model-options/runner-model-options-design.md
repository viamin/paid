---
parent: PAID
prefix: RUNNER-MODEL-OPTIONS
---

# Low-Level Design: Runner Model Options

> Companion to the high-level design (`docs/high-level-design.md`). Tracks
> GitHub issue #3666 (RDR-065, 2/8) under umbrella #3663: the
> `Runners::ModelOptions` service that backs the runner form's catalog-driven
> model dropdown (RDR-065 decisions D1–D3).

## Context

Direct-outbound runners (`opencode`, `kilocode`, `pi`, `omp`) currently ask the
user to type an exact provider model id. The form rework (#3663 chain, 5/8)
replaces that freeform input with a `<select>` populated from the `LlmModel`
catalog scoped to the runner's provider, but every consumer of "which models
can this runner use?" needs the same answer: the dropdown, controller
validation, and `Runners::DefaultTierModelIds` (tier defaults). Scattering
that derivation across call sites is how defaults and dropdowns drift apart.

## Decision

`Runners::ModelOptions` (`app/services/runners/model_options.rb`) is the
single source of truth for model choices per `(runner_key, api_provider,
auth_type)`. It returns an ordered list of `Entry` values:

1. **Free policy entry** (first, when `runner_key` is one of `opencode`,
   `kilocode`, `pi`, or `omp`, and `api_provider == "openrouter"`): value
   `"free"` — persisted as `model_policy: "free"` — with kind
   `:free_policy`. Selecting it reveals the free-model tier picker. This
   extends the originally shipped OpenCode-only gate from #3668 to the other
   direct-outbound runners in follow-up issue #3673 because their provider
   registries already include OpenRouter and the same dropdown contract
   applies.
2. **Catalog entries** (`kind: :model`): active `LlmModel` rows scoped to the
   provider, ordered family → descending capability so the form can render
   `<optgroup>`s by `family` (falling back to the catalog provider when
   `family` is blank) with the strongest model first inside each group. Each
   entry carries `value` (the catalog `model_id`), `label` (`display_name`),
   the computed `family`, and the catalog record itself so consumers can
   render quality-bar markers without re-querying.
   - For the `openrouter` provider the scope is the union of
     `provider == "openrouter"` rows (e.g. `openrouter/pareto-code`, D3) and
     `catalog_source == "openrouter_sync"` rows: synced free models are
     OpenRouter-reachable model ids even though their `provider` column holds
     the upstream vendor slug.
   - Entries are filtered through `Runners::ModelCompatibility.call` (RDR-040)
     with the caller's `auth_type`, so CLI-gated or auth-mode-gated models
     never appear as selectable options — the same contract the
     `tier_model_ids_must_be_runner_compatible` validation enforces at save
     time. `unknown` compatibility results stay selectable: compatibility
     that cannot be asserted statically must not hide catalog rows.
3. **Custom sentinel** (always trailing, `kind: :custom`): value
   `LlmModel::CUSTOM_MODEL_OPTION` with a "Custom model ID…" label.
   Selecting it reveals the existing freeform text input and keeps the
   `upsert_manual_catalog_entry` self-healing path. This consumes the
   empty-provider degradation contract from
   `direct-outbound-model-catalog` (DIRECT-OUTBOUND-CATALOG-005): when the
   provider has no active rows the result is exactly the custom sentinel, so
   no call site ever renders an empty `<select>`.

`Runners::DefaultTierModelIds` derives its standard-provider tier defaults
from this service (highest-capability compatible entry per tier), so tier
defaults and dropdown contents cannot diverge. It has no free-policy branch:
free-policy runners (`model_policy: "free"`, any direct-outbound key)
resolve their tier defaults directly through
`Runner#sync_direct_outbound_tier_models` calling
`FreeModels::DefaultTierModels`, which also rejects below-quality-bar rows —
a stricter rule that belongs to the free-model rotation path, not to option
listing (below-quality-bar models remain manually selectable, matching the
existing tier-mapping UI copy).

## What this is not

- **Not the form.** Rendering the dropdown, optgroups, custom reveal, and the
  key-driven refresh is #3667/#3669 (the form-rework slice); this segment
  only ships the option-list service and the defaults integration.
- **Not policy persistence.** `model_policy` storage, validations, and
  dispatch are #3668+; the free entry only carries the value the form will
  persist.
- **No Pareto special case.** `openrouter/pareto-code` is an ordinary catalog
  row (D3) — it flows through the provider scope with no branching here.
