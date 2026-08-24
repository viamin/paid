---
parent: PAID
prefix: RUNNERS-INDEX
---

# Low-Level Design: Runners Index Table

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> covers the presentation of the runners index table on `/runners`
> (`app/views/runners/index.html.erb`).

## Purpose

The runners index is the operator's quick status board for runner availability
and routing posture. The current table pushes the most decision-relevant state
("Status") far to the right, renders boolean routing capabilities as verbose
text, and duplicates rate-limit information in both the main table and the
expanded usage details.

This segment narrows the table to the signals operators can act on immediately:

- surface runner availability as the second visible column;
- render capability booleans as clearly non-interactive native checkboxes; and
- remove duplicated or distracting support content from the index page.

## Behavior

`app/views/runners/index.html.erb` renders one table row per runner. The index
page SHALL:

- place the `Status` column immediately after `Runner`, ahead of `Auth`, so the
  current availability badge is visible without scanning across the table;
- render `Agent Runs`, `Chat`, and `Fallback` using disabled
  `check_box_tag` inputs so the page communicates state without implying inline
  toggle behavior;
- keep the fallback-specific `rate-limit only` qualifier for API-key fallback
  runners by moving that explanation into the checkbox tooltip instead of inline
  cell text; and
- remove the top-level `Rate Limits` column while leaving the existing
  rate-limit event count available in the "Runner Usage Details" section.

## Provider Run Outcomes charts (CSP-safe rendering)

The "Provider Run Outcomes" section below the table (rendered by
`app/views/runners/_provider_outcomes.html.erb`) originally used Chartkick's
raw `column_chart` helper, which emits an inline `<script>` per chart. This
app enforces `script_src :self` with nonce-only directives
(`config/initializers/content_security_policy.rb`), so those inline scripts
are blocked by the browser and the chart placeholder ("Loading...") never
resolves — the divergence traced in issue #3458.

Every other chart surface in the app (dashboard metrics, PR cycle time,
orchestration decisions, project quality dashboard mutation trend) already
renders through the CSP-safe path: `DashboardHelper#dashboard_chartkick_chart`
emits the chart data via `data-*` attributes on a placeholder `div`, and the
`chartkick` Stimulus controller (`app/javascript/controllers/chartkick_controller.js`)
instantiates the Chartkick chart client-side with no inline script. The
provider outcomes partial now uses the same helper, and:

- element ids are derived from the entry's index in `provider_outcome_stats`
  (`provider-outcomes-chart-#{index}`) rather than interpolating the provider
  name, since provider slugs are not guaranteed to be DOM-safe identifiers.

## Removed content

The index page no longer renders the bottom "Runner Auth Setup" card. That
support content is being refactored separately and should not remain as stale
guidance on the main runners screen.

Because the auth setup card is removed, the helper code that assembled those
instruction blocks is also removed from `app/helpers/runners_helper.rb`.
Any auth troubleshooting triggered from the index page's "Test Agent" action
must therefore point operators to the remaining runner auth management surfaces
(`Edit Runner` and runner credentials) instead of referencing a page-local
setup guide that no longer exists.

## What this is not

- **Not a routing-logic change.** `@runner_states`, `Runners::UsageStats`, and
  runner enablement semantics stay unchanged.
- **Not an inline editing feature.** The disabled checkboxes are status
  indicators only; editing still lives in Settings or each runner's edit form.
