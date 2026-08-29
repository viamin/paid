---
parent: PAID
prefix: DASHBOARD-CHART-A11Y
---

# Low-Level Design: Dashboard Chart Accessibility

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the accessible text alternative for Chartkick/Chart.js
> canvas charts rendered on the dashboard and runner pages.

## Problem

`DashboardHelper#dashboard_chartkick_chart` (`app/helpers/dashboard_helper.rb`)
centralizes chart rendering for `app/views/dashboard/_metrics.html.erb`,
`_pr_cycle_time.html.erb`, `_orchestration_decisions.html.erb`, and
`runners/_provider_outcomes.html.erb`. It renders a `<div>` that the
`chartkick` Stimulus controller (`app/javascript/controllers/chartkick_controller.js`)
replaces with a Chart.js canvas. A `<canvas>` has no accessible text content
of its own, so screen reader and other non-visual users cannot inspect the
trend/outcome data the charts convey — the same data sighted users read off
axes, legends, and tooltips.

## Approach

`dashboard_chartkick_chart` renders two things instead of one:

1. The existing chart container `<div>`, now marked `aria-hidden="true"` so
   assistive tech skips over it (and its transient "Loading..." text) instead
   of reading a meaningless placeholder or nothing once Chart.js swaps in the
   canvas.
2. An adjacent `sr-only` `<table>` built from the same `data_source` the
   chart renders from — row per x-axis category, column per series, with an
   optional `<caption>` from a new `caption:` option describing the chart.

Because every call site already passes `data_source` as one of two shapes —
an `Array` of `{ name:, data: { label => value } }` series (multi-series
charts) or a bare `Hash` of `{ label => value }` (single-series, e.g. the
completion-rate line) — the table builder normalizes both into rows before
rendering, with `nil` values (days with no data) rendered as the text "No
data" rather than an empty cell.

Centralizing this in the shared helper means every current and future
dashboard/runner chart gets the same treatment automatically, with no
per-view accessibility work beyond adding a `caption:`.

## Decisions

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
- **No new JS.** The table is server-rendered alongside the existing div, so
  it works identically whether or not the chartkick controller has finished
  loading Chart.js.

## What this is not

- **Not a chart redesign.** Visual chart rendering, colors, and interactivity
  are unchanged.
- **Not a general-purpose Chartkick wrapper for the whole app.** Scope is the
  `dashboard_chartkick_chart` helper and its existing call sites.
- **Not chart-type-aware.** The table format is the same for column, line,
  and any future Chartkick chart type — it reflects the series data, not the
  visual encoding.
