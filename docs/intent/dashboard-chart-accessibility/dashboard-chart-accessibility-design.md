---
parent: PAID
prefix: DASHBOARD-CHART-A11Y
---

# Low-Level Design: Dashboard Chart Accessibility

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the accessible text alternative for Chartkick/Chart.js
> canvas charts rendered on the dashboard and runner pages.

## Problem

The dashboard and runner views (`app/views/dashboard/_metrics.html.erb`,
`_pr_cycle_time.html.erb`, `_orchestration_decisions.html.erb`, and
`runners/_provider_outcomes.html.erb`) render charts through the Chartkick
gem's stock `column_chart`/`line_chart` helpers. Two problems:

1. **CSP.** The gem's stock output is an inline `<script>` per chart. The app
   enforces `script_src :self` with nonce-only script-src directives
   (`config/initializers/content_security_policy.rb`), and these partials
   render inside turbo frames fetched by separate requests whose nonces never
   match the host page's policy, so the inline scripts are blocked and the
   "Loading..." placeholder never resolves (issues #3458, #3622).
2. **Accessibility.** Once charts do render, a `<canvas>` has no accessible
   text content of its own, so screen reader and other non-visual users cannot
   inspect the trend/outcome data the charts convey — the same data sighted
   users read off axes, legends, and tooltips.
3. **Theme coherence.** The placeholder and several dashboard chart call sites
   hard-code light-theme color values (`#999`, `#16a34a`, `#dc2626`,
   `#6366f1`, `#10b981`, `#f59e0b`). In dark mode or under future theme
   changes, those charts drift visually from the rest of the app.

## Approach

Call sites keep the standard Chartkick gem helpers (`column_chart`,
`line_chart`, … — the call-site standardization proposed in #3524).
`ChartkickHelper` (`app/helpers/chartkick_helper.rb`) overrides the gem's
single internal entry point, `Chartkick::Helper#chartkick_chart`, so every
gem chart helper in the app renders two things instead of one:

1. The chart container `<div>`, marked `aria-hidden="true"` and carrying the
   chart definition as `data-*` attributes, which the `chartkick` Stimulus
   controller (`app/javascript/controllers/chartkick_controller.js`)
   instantiates client-side — no inline script anywhere.
2. An adjacent `sr-only` `<table>` built from the same `data_source` the
   chart renders from — row per x-axis category, column per series, with an
   optional `<caption>` from a `caption:` option describing the chart.

Because every call site passes `data_source` as one of three Chartkick shapes —
an `Array` of `{ name:, data: { label => value } }` series (multi-series
charts), a bare `Hash` of `{ label => value }` (single-series, e.g. the
completion-rate line), or an `Array` of `[ label, value ]` pairs (Chartkick's
compact point-array encoding for a single series, used by the
quality-dashboard mutation-sweep trend and per-run histogram) — the table
builder normalizes all three into rows before rendering, with `nil` values
(days with no data) rendered as the text "No data" rather than an empty
cell.

The same rendering seam now owns theme tokens for chart loading text and the
dashboard-specific palettes. CSS variables on `:root` and `.dark` define the
semantic chart colors. Dashboard helpers/views pass those tokens via the
existing Chartkick option hashes, and the `chartkick` Stimulus controller
resolves `var(--token)` references against the current computed theme before
instantiating Chart.js. The theme controller emits a change event after every
theme application so already-rendered charts can re-resolve and redraw without
waiting for a full page reload.

Centralizing this in the override means every current and future chart call
site (dashboard, runner, and quality-dashboards views) gets the same
treatment automatically, with no per-view accessibility work beyond adding a
`caption:`.

## Decisions

- **Override the gem entry point, not a parallel wrapper helper.** Views call
  the gem's own `column_chart`/`line_chart`; the app-wide override keeps one
  rendering path for every gem chart type (past and future call sites)
  instead of a Paid-specific helper API that call sites must remember to use.
  The trade-off is coupling to the gem's private `chartkick_chart` seam,
  which the helper spec pins so a gem upgrade that changes it fails loudly.
- **Retain the `chartkick` Stimulus controller, superseding #3524's
  controller-cut proposal.** The gem's stock inline `<script>` output is
  blocked by the nonce-only CSP on turbo-frame responses (issues #3458,
  #3622), so removing the controller would leave every chart stuck on the
  loading placeholder. This PR standardizes on the gem's public helpers at
  the call sites, but intentionally keeps the existing controller as the
  client-side execution path.
- **`sr-only`, not a visible table.** The issue accepts either a concise
  adjacent table or an `sr-only` summary. A visible table would duplicate the
  stat tiles and legends most of these charts already render beside
  themselves; `sr-only` gives screen reader users the full dataset without
  changing the sighted layout.
- **`aria-hidden` on the chart container.** The canvas Chart.js renders has
  no text alternative of its own; without `aria-hidden`, assistive tech either
  reads the stale "Loading..." placeholder or exposes an empty canvas. Hiding
  it and pointing AT at the table sibling is the standard pattern for
  canvas-based data viz.
- **`caption:` is opt-in per call site, not inferred.** Chart captions need to
  name the actual data (e.g. "Agent runs per day, stacked by completion
  status"), which only the calling view knows; there is no reliable way to
  derive it from `data_source` or `chart_type` alone.
- **Use CSS variables for semantic chart colors, but resolve them in JS before
  Chart.js sees them.** The issue specifically wants chart palettes to
  participate in theming. CSS variables provide the theme contract; resolving
  them in the controller keeps Chart.js on concrete color strings instead of
  assuming canvas/chart plugins will interpret `var(...)` reliably.
- **Redraw charts on theme changes.** A dashboard frame does not necessarily
  reload when a user toggles dark mode. Re-rendering the existing chart on the
  theme change event keeps palettes and annotation colors coherent in-session.

## What this is not

- **Not a chart redesign.** Chart types, datasets, and interactions are
  unchanged; only palette sourcing and loading-placeholder styling now follow
  the app theme contract.
- **Not chart-type-aware.** The table format is the same for column, line,
  and any future Chartkick chart type — it reflects the series data, not the
  visual encoding.
