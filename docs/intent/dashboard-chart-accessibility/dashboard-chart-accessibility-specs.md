# EARS Specs: Dashboard Chart Accessibility

> Testable claims for the CSP-safe, accessible rendering of Chartkick gem
> charts on dashboard/runner pages. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target across specs,
> tests, and code (`grep -r DASHBOARD-CHART-A11Y-001`).

- [x] **DASHBOARD-CHART-A11Y-001** — When a Chartkick gem chart helper
  (`column_chart`, `line_chart`, …) renders a chart, the system SHALL render
  the chart as `data-*` attributes on a placeholder div (no inline
  `<script>`) for the `chartkick` Stimulus controller to instantiate, SHALL
  also render an adjacent `sr-only` `<table>` exposing the same series data
  as the chart, and SHALL mark the chart's canvas container
  `aria-hidden="true"` so assistive tech reads the table instead of the
  canvas placeholder.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_chart`,
  `chartkick_data_table`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-002** — When `data_source` is an `Array` of
  `{ name:, data: }` series (multi-series charts), the table SHALL have one
  column per series (headed by its `name`) and one row per x-axis label
  found across all series.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_table_rows`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-003** — When `data_source` is a bare `Hash` of
  `{ label => value }` (single-series charts, e.g. a completion-rate line),
  the table SHALL render a single data column rather than requiring callers
  to wrap it in a series array.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_table_rows`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-007** — When `data_source` is an `Array` of
  `[ label, value ]` pairs (Chartkick's compact point-array encoding for a
  single series, e.g. the quality-dashboard mutation-sweep trend and
  per-run histogram), the table SHALL render a single "Value" column
  rather than treating each pair as a series hash and raising on
  `series[:data]`. An empty point array SHALL render no table (matching the
  bare-hash empty behaviour) rather than raising.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_table_rows`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-004** — When a `caption:` option is passed, the
  table SHALL include it as a `<caption>` element. When omitted, the table
  SHALL still render without a caption rather than raising.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_data_table`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-005** — When a series value is `nil` (a day with
  no recorded data), the table SHALL render the cell as the text "No data"
  rather than an empty cell, so screen reader users get an explicit signal
  instead of silence.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_cell_value`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-008** — When a Chartkick helper caller passes a
  `height:` or `width:` value, the system SHALL reject values outside the
  upstream Chartkick dimension allowlist before rendering either the default
  placeholder div or an `html:` override, so placeholder sizing cannot inject
  arbitrary CSS into the inline `style` attribute.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_chart`,
  `chartkick_dimensions`).
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-009** — The default Chartkick placeholder DIV
  SHALL source its loading text color and font family from theme CSS variables
  rather than hard-coded values, so light and dark mode render through the same
  theme contract.
  *Code:* `app/helpers/chartkick_helper.rb` (`chartkick_default_placeholder`),
  `app/assets/stylesheets/application.tailwind.css`.
  *Test:* `spec/helpers/chartkick_helper_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-010** — Dashboard chart call sites and chart
  annotations SHALL source palette values from semantic theme tokens, and the
  `chartkick` Stimulus controller SHALL resolve those tokens against the active
  theme when creating or re-rendering a chart.
  *Code:* `app/helpers/dashboard_helper.rb`,
  `app/views/dashboard/_metrics.html.erb`,
  `app/views/dashboard/_pr_cycle_time.html.erb`,
  `app/javascript/controllers/chartkick_controller.js`,
  `app/javascript/controllers/theme_controller.js`,
  `app/assets/stylesheets/application.tailwind.css`.
  *Test:* `spec/helpers/chartkick_helper_spec.rb`,
  `spec/lib/chartkick_controller_node_harness_spec.rb`,
  `spec/lib/theme_controller_node_harness_spec.rb`,
  `spec/requests/dashboard_spec.rb`.

- [x] **DASHBOARD-CHART-A11Y-006** — Every dashboard/runner chart call site
  (`column_chart`/`line_chart` in `_metrics`, `_pr_cycle_time`,
  `_orchestration_decisions`, `runners/_provider_outcomes`) SHALL pass a
  `caption:` describing the chart's data.
  *Code:* `app/views/dashboard/_metrics.html.erb`,
  `app/views/dashboard/_pr_cycle_time.html.erb`,
  `app/views/dashboard/_orchestration_decisions.html.erb`,
  `app/views/runners/_provider_outcomes.html.erb`.
  *Test:* `spec/views/dashboard/metrics_partial_spec.rb`,
  `spec/views/dashboard/pr_cycle_time_partial_spec.rb`,
  `spec/views/dashboard/orchestration_decisions_partial_spec.rb`,
  `spec/views/runners/provider_outcomes_partial_spec.rb`.
