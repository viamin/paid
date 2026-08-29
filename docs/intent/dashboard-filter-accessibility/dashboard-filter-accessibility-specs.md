# EARS Specs: Dashboard Filter Accessibility

> Testable claims for exposing selected filter state to assistive tech on
> the dashboard's time range, status, and goal filter links. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is
> a grep target across specs, tests, and code
> (`grep -r DASHBOARD-FILTER-A11Y-001`).

- [x] **DASHBOARD-FILTER-A11Y-001** — When `dashboard_filter_link` renders a
  filter link with `active: true`, the system SHALL set `aria-current="page"`
  on the rendered `<a>`. When `active: false`, the system SHALL omit the
  `aria-current` attribute entirely rather than rendering it as `"false"`.
  *Code:* `app/helpers/dashboard_helper.rb` (`dashboard_filter_link`).
  *Test:* `spec/helpers/dashboard_helper_spec.rb`.

- [x] **DASHBOARD-FILTER-A11Y-002** — Every dashboard filter link list (time
  range in `_metrics.html.erb`; status and goal type in
  `_performance.html.erb`) SHALL render its links through
  `dashboard_filter_link` so exactly one link per list carries
  `aria-current="page"`, matching the visually active filter.
  *Code:* `app/views/dashboard/_metrics.html.erb`,
  `app/views/dashboard/_performance.html.erb`.
  *Test:* `spec/views/dashboard/metrics_partial_spec.rb`,
  `spec/views/dashboard/performance_partial_spec.rb`.
