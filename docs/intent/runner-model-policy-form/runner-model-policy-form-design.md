---
parent: PAID
prefix: MODEL-POLICY-FORM
---

# Low-Level Design: Runner Model Policy Form (RDR-065 catalog dropdown)

> Companion to the high-level design (`docs/high-level-design.md`). Tracks
> GitHub issue #3669 (RDR-065, 6/8), implementing decision D1 from #3663
> behind the `runner_model_policy_form` feature flag. Builds on
> `Runners::ModelOptions` (`docs/intent/opencode-model-policy` and #3666) and
> the key-derived `api_provider` work (#3667) that already shipped.

## Context

Direct-outbound runners (`opencode`, `kilocode`, `pi`, `omp`) let a user type
a free-text model id, or fall back to a manual text input whenever the
derived provider has no catalog rows. RDR-065 D1 replaces this with a
catalog-driven `<select>` sourced from `Runners::ModelOptions`, with a
trailing "Custom model ID…" sentinel that reveals the free-text input on
demand instead of only when the catalog happens to be empty.

This segment covers the flagged form surface only: the `<select>`, the Free
policy sentinel (`opencode` + OpenRouter only, per D6), and the Custom
sentinel reveal. It does not change:

- `Runners::ModelOptions` itself (already shipped, `MODEL-POLICY-FORM-*`
  reuses `RUNNER-MODEL-OPTIONS-*` verbatim).
- Execution dispatch (`Runners::ResolveTierModel` already resolves free- and
  specific-policy runners from `tier_model_ids`/`tier_models` regardless of
  this form; dispatch-side policy plumbing is tracked separately).
- The legacy `openrouter_free`/`openrouter_pareto` runner-key migration.

The flag defaults off; flag-off requests render the pre-existing free-text
form byte-for-byte unchanged.

## Design

### Feature flag

`FeatureFlags::DEFINITIONS[:runner_model_policy_form]` (see
`app/services/feature_flags.rb`), checked via the `feature_enabled?` view
helper (`app/controllers/application_controller.rb`) with no `project:`
argument — Runner records are account-scoped, not project-scoped, so the
tenant override falls back to `Current.account`.

### Model field partial

`app/views/runners/_catalog_model_field.html.erb`, rendered once per
direct-outbound runner-key block (`opencode`, `kilocode`, `pi`, `omp`) in
`app/views/runners/_form.html.erb` when the flag is on; the pre-existing
markup renders unchanged when it is off. Locals: `runner_key`,
`service_types`, `current_service_type`, `current_model_id`,
`current_model_policy` (`opencode` only), `optional`, `supports_model_policy`
(`opencode` only).

For each service type the runner-key could resolve to, the partial calls
`Runners::ModelOptions.call(runner_key:, api_provider:, auth_type: "api_key")`
via `RunnersHelper#catalog_model_entries_by_service_type` and embeds the full
per-service-type entry set as JSON in
`data-model-entries-by-service-type` — not just the currently-selected
service type's entries — so the Stimulus controller can re-render the
`<select>` when the user switches API keys without a page round-trip. This
mirrors the pre-existing `data-model-options-by-service-type` mechanism used
by the legacy free-text/manual-entry select.

### Initial selection

`RunnersHelper#catalog_model_initial_selection` resolves which `<option>`
should be selected on first render:

1. `model_policy == "free"` → the Free sentinel (`Runners::ModelOptions::FREE_POLICY_VALUE`).
2. `current_model_id` blank → the placeholder.
3. `current_model_id` matches a `:model` entry's value → that catalog row.
4. Otherwise → the Custom sentinel (`LlmModel::CUSTOM_MODEL_OPTION`), with the
   manual input prefilled from `current_model_id`.

Case 4 covers both a genuinely custom (not-yet-cataloged) id and a
previously-cataloged id that has since been deactivated — the same
degradation the legacy manual-entry fallback already handled.

### Name-swap instead of hide/disable

Only one of `{select, manual input}` carries a `name` attribute at a time, so
neither sentinel value (`"free"`, `"custom"`) is ever submitted as the model
id:

- Selecting **Custom** moves the `name` from the select to the manual input
  (which is revealed). The select stays enabled so the user can switch back
  to a catalog row without reloading the page.
- Selecting **Free** (opencode + OpenRouter only) drops the `name` from both
  the select and the manual input, and sets the hidden
  `runner[config][opencode][model_policy]` field to `"free"`. No model id is
  submitted — `sync_direct_outbound_tier_models` already populates
  `tier_model_ids` from `FreeModels::DefaultTierModels` for any
  `free_model_policy?` runner (MODEL-POLICY-005), so the dropdown does not
  need to render a full tier picker for the general case.

`app/javascript/controllers/runner_form_controller.js` implements this via
`syncPolicyModelField`, invoked on `change` and on every
`refreshPolicyModelOptions` re-render (including initial `connect()`), so a
server-rendered initial "free"/"custom" selection and a client-driven one
converge on the same DOM state. `modelSelectFor`/`serviceTypesFor` generalize
the pre-existing `dynamicModelSelectTargets`-only helpers to search both the
legacy and the new target lists, since exactly one variant renders per page
load.

### Scope not carried by this segment

- Kilocode/Pi/Oh My Pi never receive a Free entry — `Runners::ModelOptions`
  gates it to `runner_key == "opencode"` — so `supports_model_policy` is
  `false` and no `model_policy` hidden field renders for those three.
- The dedicated legacy `openrouter_free`/`openrouter_pareto` runner keys are
  untouched: they never reach the four direct-outbound blocks this segment
  covers, and keep rendering their existing tier-mapping sub-form.
