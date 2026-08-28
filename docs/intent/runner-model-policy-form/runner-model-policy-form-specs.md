# EARS Specs: Runner Model Policy Form (RDR-065 catalog dropdown)

> Testable claims for the flagged catalog-driven Model `<select>` on
> direct-outbound runners. Status markers: `[x]` implemented · `[ ]` active
> gap · `[D]` deferred. Each ID is a grep target across specs, tests, and
> code (`grep -r MODEL-POLICY-FORM-001`).

## Rollout guard

- [x] **MODEL-POLICY-FORM-001** — `FeatureFlags::DEFINITIONS` SHALL define
  `runner_model_policy_form`, defaulting off. When off, the runner form
  SHALL render the pre-existing free-text/manual-entry Model field for
  `opencode`, `kilocode`, `pi`, and `omp` unchanged. When on, those four
  runner-key blocks SHALL render the catalog-driven `<select>` from
  `Runners::ModelOptions` instead.

## Initial selection

- [x] **MODEL-POLICY-FORM-002** — On the edit form for a persisted
  direct-outbound runner, the Model `<select>` SHALL preselect: the Free
  sentinel when `model_policy == "free"`; the matching catalog `<option>`
  when the stored model id is an active catalog row for the runner's
  resolved provider; otherwise the Custom sentinel, with the manual text
  input prefilled from the stored model id (covers both a genuinely custom
  id and a previously-cataloged id later deactivated).

## Sentinel submission

- [x] **MODEL-POLICY-FORM-003** — Selecting the Custom sentinel SHALL reveal
  the manual text input and move the `runner[config][<key>][model]` `name`
  attribute onto it, so the literal sentinel value is never submitted as the
  model id. The `<select>` SHALL remain enabled so the user can switch back
  to a catalog row without reloading the page.
- [x] **MODEL-POLICY-FORM-004** — Selecting the Free sentinel (opencode +
  OpenRouter only) SHALL drop the `name` attribute from both the `<select>`
  and the manual input, and SHALL set the hidden
  `runner[config][opencode][model_policy]` field to `"free"`; no model id
  SHALL be submitted for this selection.
- [ ] **MODEL-POLICY-FORM-005** — KiloCode, Pi, and Oh My Pi SHALL NOT render
  a `model_policy` field or a Free sentinel option in any state; only
  `opencode` supports the Free policy today (RDR-065 D6). Deferred: porting
  the Free policy to these three runners is tracked separately (#3673) and
  out of scope for this segment.

## Data for client-side re-render

- [x] **MODEL-POLICY-FORM-006** — The `<select>`'s
  `data-model-entries-by-service-type` attribute SHALL carry
  `Runners::ModelOptions` entries for every service type the runner key
  could resolve to (not only the currently-selected one), so
  `runner_form_controller.js` can repopulate the dropdown when the user
  switches API keys without a full page reload.
