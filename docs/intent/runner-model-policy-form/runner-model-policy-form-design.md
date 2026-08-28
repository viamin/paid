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

### Stable server fallback plus JS hide/disable

The server-rendered form must remain submission-valid even if Stimulus never
boots, so the markup submits a stable shape and the controller normalizes it
back into the persisted config contract:

- The `<select>` always submits `runner[config][<key>][model]`, including the
  sentinel values `"free"` and `"custom"`.
- The manual input always submits
  `runner[config][<key>][manual_model]`; without JS it remains visible so the
  user can still choose **Custom** and enter a model id in the same request.
- `RunnersController#runner_params` normalizes the submission:
  - `"custom"` copies `manual_model` into `model` and forces
    `model_policy = "specific"` for `opencode`.
  - `"free"` clears `model` and forces `model_policy = "free"` for
    `opencode`.
  - Any non-Free row forces `model_policy = "specific"` for `opencode`, so a
    stale hidden input from an initially-free render cannot keep the runner on
    the Free policy.

`app/javascript/controllers/runner_form_controller.js` still implements the
interactive behavior via `syncPolicyModelField`, invoked on `change` and on
every `refreshPolicyModelOptions` re-render (including initial `connect()`),
but now it only manages visibility/disabled state and the hidden
`model_policy` field. `modelSelectFor`/`serviceTypesFor` generalize the
pre-existing `dynamicModelSelectTargets`-only helpers to search both the
legacy and the new target lists, since exactly one variant renders per page
load.

### Scope not carried by this segment

- Kilocode/Pi/Oh My Pi never receive a Free entry — `Runners::ModelOptions`
  gates it to `runner_key == "opencode"` — so `supports_model_policy` is
  `false` and no `model_policy` hidden field renders for those three.
- The dedicated legacy `openrouter_free`/`openrouter_pareto` runner keys are
  untouched: they never reach the four direct-outbound blocks this segment
  covers, and keep rendering their existing tier-mapping sub-form.
