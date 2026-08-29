# EARS Specs: Dashboard Chart Accessibility

> Testable claims for the accessible non-canvas fallback on dashboard/runner
> Chartkick charts. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r DASHBOARD-CHART-A11Y-001`).

- [x] **DASHBOARD-CHART-A11Y-001** — When `dashboard_chartkick_chart` renders
  a chart, the system SHALL also render an adjacent `sr-only` `<table>`
  exposing the same series data as the chart, and SHALL mark the chart's
  canvas container `aria-hidden="true"` so assistive tech reads the table
  instead of the canvas placeholder.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_chartkick_chart`,
  `dashboard_chart_data_table`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-002** — When `data_source` is an `Array` of
  `{ name:, data: }` series (multi-series charts), the table SHALL have one
  column per series (headed by its `name`) and one row per x-axis label
  found across all series.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_chart_table_rows`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-003** — When `data_source` is a bare `Hash` of
  `{ label => value }` (single-series charts, e.g. a completion-rate line),
  the table SHALL render a single data column rather than requiring callers
  to wrap it in a series array.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_chart_table_rows`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-004** — When a `caption:` option is passed, the
  table SHALL include it as a `<caption>` element. When omitted, the table
  SHALL still render without a caption rather than raising.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_chart_data_table`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-005** — When a series value is `nil` (a day with
  no recorded data), the table SHALL render the cell as the text "No data"
  rather than an empty cell, so screen reader users get an explicit signal
  instead of silence.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_chart_cell_value`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-006** — Every dashboard/runner call site of
  `dashboard_chartkick_chart` (`_metrics`, `_pr_cycle_time`,
  `_orchestration_decisions`, `runners/_provider_outcomes`) SHALL pass a
  `caption:` describing the chart's data.
  *Code:* `app/views/dashboard/_metrics.html.erb`,
  `app/views/dashboard/_pr_cycle_time.html.erb`,
  `app/views/dashboard/_orchestration_decisions.html.erb`,
  `app/views/runners/_provider_outcomes.html.erb`.
  *Test:* `spec/views/dashboard/*_partial_spec.rb`.
