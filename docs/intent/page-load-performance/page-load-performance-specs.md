# EARS Specs: Page Load Performance

> Testable claims for page load measurement during PR screenshot capture, the
> per-project load-time ledger and its export, before/after regression
> detection, and the opt-in performance follow-up run. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r PAGE-LOAD-MEASURE-001`).

## Measurement

- [x] **PAGE-LOAD-MEASURE-001** — Where page load measurement is enabled for a
  project (`screenshot_settings.performance.enabled`), the container screenshot
  capture path SHALL navigate each captured route `samples` times with tracing
  disabled and record, per navigation, time to first byte, DOM content loaded,
  load, first contentful paint, and largest contentful paint, each in whole
  milliseconds relative to navigation start.
  *Code:* `Screenshots::ContainerCapture#capture_runner_script`, `#page_load_samples`.
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-002** — Before sampling the first route of a capture,
  the container screenshot capture path SHALL perform one warm-up navigation
  whose timings are discarded, so application boot and cold caches are not
  attributed to whichever route the pull request's diff placed first.
  *Code:* `Screenshots::ContainerCapture#capture_runner_script` (`measureRoute`).
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-003** — For each measured route, the system SHALL
  report the median of the samples per metric and SHALL retain the sample
  count and the per-sample values alongside it.
  *Code:* `Screenshots::ContainerCapture#capture_runner_script` (`summarize`).
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-004** — For each measured route, the system SHALL
  record the HTTP status of the final measured navigation.
  *Code:* `Screenshots::ContainerCapture#capture_runner_script` (`collectTiming`).
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-005** — Where a paint metric (first contentful paint,
  largest contentful paint) is unavailable for a route, the system SHALL record
  it as null and SHALL NOT substitute zero.
  *Code:* `PageLoadPerformance::RecordMeasurements#medians`.
  *Test:* `spec/services/page_load_performance/record_measurements_spec.rb`, `spec/models/page_load_measurement_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-006** — If timing collection fails for a route during
  container capture, then the system SHALL still capture that route's
  screenshot, omit that route from the timing document, and log the failure.
  *Code:* `Screenshots::ContainerCapture#capture_runner_script` (`measureRoute` rescue).
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-007** — When container capture measures routes, the
  capture runner SHALL write the timings as a single `page-load-timings.json`
  document in the screenshot output directory, and the host SHALL collect it
  from the workspace alongside the captured screenshots.
  *Code:* `Screenshots::ContainerCapture::TIMING_DOCUMENT`, `#read_timing_document`.
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-008** — If the timing document is absent or cannot be
  parsed after container capture, then the system SHALL complete the capture,
  publish, and pull request comment exactly as it does when measurement is
  disabled, and SHALL log the omission.
  *Code:* `Screenshots::ContainerCapture#read_timing_document`, `PageLoadPerformance::RecordMeasurements#call`.
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`, `spec/services/page_load_performance/record_measurements_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-009** — Where page load measurement is disabled for a
  project, the container screenshot capture path SHALL navigate each route once
  and record no measurements.
  *Code:* `Screenshots::ContainerCapture#page_load_samples`.
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-010** — The rake/CI screenshot capture path
  (`Screenshots::Capture` and `screenshots`-branch storage) SHALL NOT record
  page load measurements; measurement is scoped to the container capture path
  that runs as part of an agent run. Agent verification runs are likewise
  unmeasured while `PAGE-LOAD-MEASURE-012` remains deferred.
  *Code:* `Screenshots::Capture`.
  *Test:* `spec/services/screenshots/capture_page_load_spec.rb`,
  `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [D] **PAGE-LOAD-MEASURE-012** — Where an agent verification run drives the
  provisioned browser, the system SHALL record page load measurements for the
  pages it navigates, attributed to the verification source and excluded from
  regression comparison. Deferred: Paid provisions the verification browser but
  does not drive it — navigation happens through a third-party `playwright-mcp`
  server, which offers no interception point for timing a navigation or
  attaching route identity to it.

- [x] **PAGE-LOAD-MEASURE-011** — While the per-capture sampling time budget
  is exhausted, the system SHALL measure each remaining route with a single
  navigation and record it with a sample count of one, rather than continuing
  to sample and risking the capture timeout.
  *Code:* `PageLoadPerformance::Settings::SAMPLE_BUDGET_SECONDS`, `Screenshots::ContainerCapture#capture_runner_script`.
  *Test:* `spec/services/screenshots/container_capture_page_load_spec.rb`, `spec/services/page_load_performance/record_measurements_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-013** — When the host reads the timing document the
  capture runner wrote, the system SHALL treat it as untrusted container output:
  it SHALL ignore a document larger than the configured size cap, retain no more
  routes than the configured route cap, truncate route names and paths to their
  stored column widths, discard non-positive and out-of-range metric values, and
  retain no more sample values per metric than were requested.
  *Code:* `Screenshots::ContainerCapture#read_timing_document`,
  `PageLoadPerformance::TimingDocument`.
  *Test:* `spec/services/page_load_performance/timing_document_spec.rb`,
  `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-MEASURE-014** — The system SHALL record the viewport a
  measurement was taken at from the host's resolved screenshot configuration
  rather than from the container-written timing document, so a container cannot
  disqualify its own comparisons by reporting a viewport it did not render at.
  *Code:* `Screenshots::ContainerCapture#record_page_load_performance!`,
  `PageLoadPerformance::RecordMeasurements`.
  *Test:* `spec/services/page_load_performance/record_measurements_spec.rb`,
  `spec/services/screenshots/container_capture_page_load_spec.rb`.

## Ledger

- [x] **PAGE-LOAD-LEDGER-001** — When container capture produces route timings,
  the system SHALL persist one measurement row per route recording account,
  project, agent run, pull request number, commit SHA, route name, route path,
  HTTP status, the median value of each metric, the per-sample values, the
  sample count, the viewport, and the capture timestamp.
  *Code:* `PageLoadMeasurement`, `PageLoadPerformance::RecordMeasurements`.
  *Test:* `spec/models/page_load_measurement_spec.rb`, `spec/services/page_load_performance/record_measurements_spec.rb`.

- [x] **PAGE-LOAD-LEDGER-002** — Page load measurement rows SHALL be scoped to
  their account under forced row-level security, so a measurement is readable
  only within its own tenant context.
  *Code:* `db/migrate/20260824021817_create_page_load_measurements.rb`, `db/migrate/20260824021819_create_page_load_regression_findings.rb`.
  *Test:* `spec/migrations/create_page_load_measurements_spec.rb`.

- [x] **PAGE-LOAD-LEDGER-003** — When a capture records a route that already has
  a measurement for the same project, pull request number, and commit SHA, the
  system SHALL replace the existing row rather than appending a second one, so
  a retried capture does not become its own baseline.
  *Code:* `idx_page_load_measurements_capture_route`, `PageLoadPerformance::RecordMeasurements#record`.
  *Test:* `spec/models/page_load_measurement_spec.rb`, `spec/services/page_load_performance/record_measurements_spec.rb`, `spec/migrations/create_page_load_measurements_spec.rb`.

- [x] **PAGE-LOAD-LEDGER-004** — The system SHALL delete page load measurements
  older than the screenshot retention period, so the ledger's depth matches the
  artifacts it describes.
  *Code:* `PageLoadMeasurement.prune_older_than`, `ScreenshotCleanupJob#prune_page_load_measurements`.
  *Test:* `spec/models/page_load_measurement_spec.rb`, `spec/jobs/screenshot_cleanup_job_spec.rb`.

## Export

- [x] **PAGE-LOAD-EXPORT-001** — When measurements are persisted for a project
  and object storage is configured, the system SHALL regenerate, from every
  route with measurements inside the retention window, a single per-project
  document at `screenshots/{org}/{repo}/page-load-times.json` from
  the persisted measurements rather than editing the previously stored
  document.
  *Code:* `PageLoadPerformance::ExportLedger`, `Screenshots::Storage#upload_document`.
  *Test:* `spec/services/page_load_performance/export_ledger_spec.rb`, `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-EXPORT-002** — The exported per-project document SHALL
  contain, for each route, the 100 most recent measurements newest-first and a
  summary carrying the trailing median, the best and worst recorded values, and
  the direction of the most recent comparison.
  *Code:* `PageLoadPerformance::ExportLedger::ENTRIES_PER_ROUTE`, `#routes`, `#summary`.
  *Test:* `spec/services/page_load_performance/export_ledger_spec.rb`.

- [x] **PAGE-LOAD-EXPORT-003** — Where object storage is not configured for a
  project, the system SHALL still persist measurements and evaluate
  regressions, SHALL skip the export, and SHALL log the skip.
  *Code:* `PageLoadPerformance::ExportLedger#call`.
  *Test:* `spec/services/page_load_performance/export_ledger_spec.rb`.

## Regression detection

- [x] **PAGE-LOAD-REGRESSION-001** — When a measured route has an earlier
  measurement for the same project and pull request at a different commit SHA,
  the system SHALL compare the two using the project's configured comparison
  metric, falling back to the load metric when the configured metric is null in
  either measurement.
  *Code:* `PageLoadPerformance::EvaluateRegressions#resolved_metric`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-002** — The system SHALL flag a route as regressed
  only when the current value exceeds the baseline by more than both the
  configured ratio and the configured absolute floor in milliseconds.
  *Code:* `PageLoadPerformance::EvaluateRegressions#regressed?`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-003** — If a measured route has no earlier
  measurement for the same pull request at a different commit, then the system
  SHALL record the measurement, make no comparison, and report the route as
  having no baseline rather than as unchanged or improved.
  *Code:* `PageLoadPerformance::EvaluateRegressions#evaluate`, `PageLoadMeasurement#baseline`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-004** — If a measured route and its baseline
  differ in route path, HTTP status, or viewport, then the system SHALL report
  the route as not comparable and SHALL NOT raise a regression finding for it.
  *Code:* `PageLoadPerformance::EvaluateRegressions#comparable?`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-005** — When the system flags a route as
  regressed, it SHALL persist an open regression finding recording the route,
  the comparison metric, the baseline and current values, the sample spread,
  and the commit SHAs compared, and SHALL mark the finding actionable when the
  route is present in the screenshot hints of the capture that produced it.
  *Code:* `PageLoadPerformance::EvaluateRegressions#raise_finding`, `PageLoadRegressionFinding`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`, `spec/services/screenshots/container_capture_page_load_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-009** — When a route that already has an open
  regression finding for the same pull request is flagged again by a later
  capture, the system SHALL update that finding with the newer comparison
  rather than opening a second finding for the route.
  *Code:* `idx_page_load_findings_one_open_per_route`, `PageLoadPerformance::EvaluateRegressions#raise_finding`.
  *Test:* `spec/models/page_load_regression_finding_spec.rb`, `spec/services/page_load_performance/evaluate_regressions_spec.rb`, `spec/migrations/create_page_load_measurements_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-006** — When a later capture at a newer commit
  evaluates a route that has an open regression finding and the route is within
  threshold, the system SHALL resolve that finding.
  *Code:* `PageLoadPerformance::EvaluateRegressions#resolve_finding`, `PageLoadRegressionFinding#resolve!`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`, `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-007** — When measurements exist for a capture, the
  screenshot pull request comment SHALL include a per-route table of baseline
  value, current value, and delta, distinguishing regressed, unchanged, not
  comparable, and no-baseline routes, and SHALL show the trailing median from
  the ledger as trend context.
  *Code:* `PageLoadPerformance::CommentSection`, `Screenshots::PrComment#build_comment_body`.
  *Test:* `spec/services/page_load_performance/comment_section_spec.rb`.

- [x] **PAGE-LOAD-REGRESSION-008** — When later captures at newer commits for
  the same pull request no longer measure a route that has an open regression
  finding, the system SHALL supersede that finding rather than leaving it open,
  so a pull request does not accumulate performance work for routes it no
  longer touches.
  *Code:* `PageLoadPerformance::EvaluateRegressions#supersede_unmeasured_findings!`.
  *Test:* `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

## Follow-up run

- [x] **PAGE-LOAD-FOLLOWUP-001** — Where a project enables performance
  follow-up runs (`screenshot_settings.performance.followup_enabled`) and an
  open regression finding is marked actionable for that pull request, the pull
  request scanner SHALL emit a `page_load_regression` trigger for it. This
  segment decides whether a finding warrants a trigger; `focused-agent-runs`
  owns what the trigger maps to and its focus priority.
  *Code:* `ScanPaidPrsActivity#page_load_regression_triggers`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`, `spec/models/page_load_regression_finding_spec.rb`.

- [x] **PAGE-LOAD-FOLLOWUP-002** — Where a project does not enable performance
  follow-up runs, the system SHALL still persist and report regression
  findings, and SHALL NOT emit a `page_load_regression` trigger.
  *Code:* `ScanPaidPrsActivity#page_load_regression_triggers`, `PageLoadPerformance::Settings#followup_enabled?`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`.

- [x] **PAGE-LOAD-FOLLOWUP-003** — Where a regression finding is for a route
  that was not present in the screenshot hints of the capture that produced it
  (a route the pull request did not touch), the system SHALL record and report
  the finding with its actionable flag unset and SHALL NOT emit a
  `page_load_regression` trigger for it.
  *Code:* `PageLoadPerformance::EvaluateRegressions#raise_finding` (actionable), `ScanPaidPrsActivity#page_load_regression_triggers`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`, `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-FOLLOWUP-004** — When a performance follow-up run is queued,
  the system SHALL copy the finding's evidence — route, comparison metric,
  baseline and current values, sample spread, and the pull request's changed
  files — onto the queued run's metadata, so the prompt is built from a stable
  record rather than re-measuring.
  *Code:* `QueueAgentRunActivity#snapshot_page_load_evidence!`, `PageLoadRegressionFinding#evidence`.
  *Test:* `spec/temporal/activities/queue_agent_run_activity_page_load_spec.rb`.

- [x] **PAGE-LOAD-FOLLOWUP-005** — While a performance follow-up run for a
  pull request is queued or running, the system SHALL NOT emit a further
  `page_load_regression` trigger for that pull request.
  *Code:* `ScanPaidPrsActivity#active_page_load_run?`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`.

- [x] **PAGE-LOAD-FOLLOWUP-006** — The system SHALL emit at most
  `MAX_FOLLOWUP_ATTEMPTS` `page_load_regression` triggers for a given finding,
  counting each queued follow-up run, so a regression the agent cannot fix stops
  consuming runner budget instead of requeueing on every scan cycle. When the
  attempts are exhausted the finding SHALL remain open and reported, and SHALL
  say in the pull request comment that automated attempts are exhausted.
  *Code:* `PageLoadRegressionFinding#followup_exhausted?`,
  `ScanPaidPrsActivity#page_load_regression_triggers`,
  `QueueAgentRunActivity#snapshot_page_load_evidence!`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_page_load_spec.rb`,
  `spec/temporal/activities/queue_agent_run_activity_page_load_spec.rb`.

## Configuration

- [x] **PAGE-LOAD-CONFIG-001** — The system SHALL resolve page load settings
  from `screenshot_settings.performance` with defaults `enabled` true,
  `followup_enabled` false, `comparison_metric` largest contentful paint,
  `regression_ratio` 0.25, `regression_floor_ms` 150, and `samples` 3.
  *Code:* `PageLoadPerformance::Settings`, `Project::DEFAULT_SCREENSHOT_SETTINGS`, `Project#normalize_page_load_settings`.
  *Test:* `spec/models/project_page_load_settings_spec.rb`, `spec/services/page_load_performance/evaluate_regressions_spec.rb`.

- [x] **PAGE-LOAD-CONFIG-002** — If a project's page load settings carry a
  comparison metric outside the recorded metric set, a non-positive ratio, a
  negative floor, or a sample count outside 1–10, then the system SHALL reject
  the settings with a validation error naming the offending key.
  *Code:* `Project#validate_page_load_settings`.
  *Test:* `spec/models/project_page_load_settings_spec.rb`.
