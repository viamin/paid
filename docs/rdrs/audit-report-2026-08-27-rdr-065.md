# RDR-065 Closeout Audit

- **RDR**: [RDR-065](RDR-065-runner-model-selection-ux.md)
- **Audit date**: 2026-08-27
- **Closeout issue**: [#3672](https://github.com/viamin/paid/issues/3672)
- **Conclusion**: Partially Implemented

## Scope

Audit shipped code, tests, and docs against RDR-065 and umbrella issue #3663:
catalog coverage, `Runners::ModelOptions`, key-derived provider behavior,
`model_policy`, form cutover, dispatch, and migration/removal of legacy
OpenRouter pseudo-keys.

## Shipped

### Catalog coverage

- Implemented: `Models::SeedKnownModels::KNOWN_MODELS` now includes the
  missing direct-outbound providers and a seeded `openrouter/pareto-code`
  entry. Evidence:
  `app/services/models/seed_known_models.rb:556`,
  `app/services/models/seed_known_models.rb:703`,
  `spec/services/models/seed_known_models_spec.rb:194`,
  `spec/services/models/seed_known_models_spec.rb:204`.
- Implemented: OpenRouter free sync does not retire the seeded Pareto row.
  Evidence:
  `spec/services/free_models/sync_spec.rb:93`.

### `Runners::ModelOptions`

- Implemented: `Runners::ModelOptions` exists and emits provider-scoped model
  entries, the OpenRouter Free sentinel, and the custom-model sentinel while
  filtering through `Runners::ModelCompatibility`. Evidence:
  `app/services/runners/model_options.rb:8`,
  `app/services/runners/model_options.rb:48`,
  `app/services/runners/model_options.rb:54`,
  `app/services/runners/model_options.rb:72`,
  `app/services/runners/model_options.rb:81`,
  `spec/services/runners/model_options_spec.rb`.
- Implemented: `Runners::DefaultTierModelIds` now derives standard-provider
  defaults from `Runners::ModelOptions`, keeping defaults aligned with the
  dropdown source. Evidence:
  `app/services/runners/default_tier_model_ids.rb:46`.

### Key-derived provider

- Implemented: the effective direct-outbound provider is derived from the
  selected API key via `derived_api_provider_for` in the runner accessors
  rather than user-entered state. Evidence:
  `app/models/runner.rb:387`,
  `app/models/runner.rb:436`,
  `app/models/runner.rb:464`,
  `app/models/runner.rb:486`.
- Implemented: request specs confirm grouped API keys and the absence of the
  direct-outbound `api_provider` select in the API-key form. Evidence:
  `spec/requests/runners_spec.rb:1046`.

### `model_policy`

- Implemented: `Runner::MODEL_POLICIES`, `Runner#opencode_model_policy`,
  `Runner#free_model_policy?`, and the policy validations exist and are covered
  by model/request specs. Evidence:
  `app/models/runner.rb:21`,
  `app/models/runner.rb:400`,
  `app/models/runner.rb:412`,
  `app/models/runner.rb:1226`,
  `app/models/runner.rb:1270`,
  `app/controllers/runners_controller.rb:221`,
  `spec/models/runner_spec.rb:777`,
  `spec/requests/runners_spec.rb:941`.

## Gaps

### Rollout guard and form cutover

- Gap: the RDR-required feature flag `runner_model_policy_form` is not defined
  in `FeatureFlags::DEFINITIONS`. Evidence:
  `app/services/feature_flags.rb:18-40` contains other flags but no
  `runner_model_policy_form`.
- Gap: the final model-policy-driven form did not ship. The current form still
  renders the direct-outbound model select/manual-input flow keyed by runner,
  not the flagged RDR-065 Free/Pareto/specific/custom state machine. Evidence:
  `app/views/runners/_form.html.erb`,
  `app/javascript/controllers/runner_form_controller.js`.
- Existing tracking issue: [#3669](https://github.com/viamin/paid/issues/3669).

### Dispatch and execution parity

- Gap: `Runners::ResolveTierModel` does not read `model_policy`; it still
  resolves only from `tier_models`, `tier_model_ids`, provider values, and
  defaults. Evidence:
  `app/services/runners/resolve_tier_model.rb:16-34`.
- Gap: enabled free-policy OpenCode runners are still explicitly rejected by
  validation, proving dispatch was not cut over. Evidence:
  `app/models/runner.rb:1305`,
  `spec/models/runner_spec.rb:814`,
  `spec/requests/runners_spec.rb:956`.
- Existing tracking issue: [#3670](https://github.com/viamin/paid/issues/3670).

### Legacy key migration and cleanup

- Gap: legacy `openrouter_free` / `openrouter_pareto` runner keys still exist
  in the runtime model and registries. Evidence:
  `app/models/runner.rb:12-14`,
  `lib/runner_support.rb`,
  `app/temporal/activities/run_agent_activity.rb:870`.
- Gap: the umbrella acceptance case "OpenCode + OpenRouter key -> Free" is not
  achievable end-to-end because the free policy remains disabled for active
  OpenCode runners and the legacy pseudo-keys are still the active path.
- Existing tracking issue: [#3671](https://github.com/viamin/paid/issues/3671).

## Acceptance scenario audit

- `OpenCode` + OpenRouter key -> Free/Pareto/specific/custom: partial.
  Specific/custom are supported; free-policy save exists only in disabled
  pre-configuration form and dispatch is still blocked; pseudo-key migration is
  not complete.
- Anthropic key -> Opus/Sonnet/Haiku: partial. Provider-derived filtering is in
  place, but the final flagged form walkthrough was not shipped.
- z.ai Coding Plan -> glm-only: partial. Catalog/manual-entry behavior exists,
  but the final flagged walkthrough was not shipped.
- Subscription runners untouched: implemented. The current changes are scoped
  to direct-outbound/API-key runner surfaces; no evidence of subscription-form
  changes was found in this closeout.

## Issue and label hygiene

- No new gap issues were filed in this audit because the unmet criteria are
  already tracked in the still-open child issues
  [#3669](https://github.com/viamin/paid/issues/3669),
  [#3670](https://github.com/viamin/paid/issues/3670), and
  [#3671](https://github.com/viamin/paid/issues/3671).
- Label check: closeout issue [#3672](https://github.com/viamin/paid/issues/3672)
  currently carries `documentation` and `P2`, and umbrella issue
  [#3663](https://github.com/viamin/paid/issues/3663) carries `enhancement`
  and `P2`; neither carries a default auto-pick skip label.

## Conclusion

RDR-065 should be marked **Partially Implemented**, not `Implemented`. The
catalog, model-option, and key-derivation foundations shipped, but the RDR's
rollout guard, final form, dispatch cutover, and legacy key migration/removal
remain incomplete.
