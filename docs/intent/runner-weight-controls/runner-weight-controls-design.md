---
parent: PAID
prefix: RUNNER-WEIGHTS
---

# Low-Level Design: Runner Weight Controls (Settings UI)

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> covers the client-side behavior of the manual weight inputs on the Runner
> Priority settings page (`/runners`), specifically how they react to the
> "Auto-balance weights based on usage quotas" checkbox before the form is
> submitted.

## Purpose

`UserSetting#auto_weight_enabled` switches `Runner.weight` between two
sources of truth: manually-entered per-runner weights, and quota-derived
weights recalculated periodically by `Runners::QuotaBalanceService` (see
`app/jobs/runner_quota_balance_job.rb`). While auto-balancing is on, manual
weight inputs are rendered read-only because editing them would have no
effect until auto-balancing is turned off and the setting is saved.

This LLD covers only the settings-page presentation layer: keeping the
disabled/read-only state of the weight inputs and the accompanying notice in
sync with the checkbox's *current, unsaved* value, so the user gets
immediate feedback without a save round trip. It does not change the
persisted semantics of `auto_weight_enabled` or `Runners::QuotaBalanceService`
— those take effect on save exactly as before.

## Behavior

`app/views/runners/_settings.html.erb` renders the weight section wrapped in
`data-controller="runner-weights"` (`app/javascript/controllers/runner_weights_controller.js`):

- The `auto_weight_enabled` checkbox is the controller's `autoWeight` target
  and fires `change->runner-weights#toggle`.
- Each per-runner weight `number_field_tag` is a `weight` target.
- The amber "Auto-weighting is active..." notice is the `notice` target.

On `toggle`, the controller sets `disabled` on every `weight` target and
`hidden` on the `notice` target to match the checkbox's live `checked` state
— mirroring, without a server round trip, the same server-rendered state
(`disabled: user_setting.auto_weight_enabled?`) used on initial page load.

## What this is not

- **Not a data-integrity control.** The field only takes effect on save;
  toggling it client-side does not change `Runner.weight` or bypass server
  validation.
- **Not a change to `Runners::QuotaBalanceService`.** Auto-balancing
  continues to run on its existing schedule based on the persisted setting.
