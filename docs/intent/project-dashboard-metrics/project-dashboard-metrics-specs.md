# EARS Specs: Project Dashboard Metrics

> Testable claims for project-level dashboard metrics.

- [x] **PROJECT-DASHBOARD-METRICS-001** — When an authorized viewer opens a
  project page, the system SHALL display the project's average merge time,
  average CI time, and average tokens per PR in a concise dashboard above the
  existing project statistics.
  *Tests:* `spec/requests/projects_spec.rb` ("project dashboard metrics").
  *Code:* `app/controllers/projects_controller.rb#show`,
  `app/views/projects/_dashboard_metrics.html.erb`.

- [x] **PROJECT-DASHBOARD-METRICS-002** — The system SHALL refresh metric
  snapshots for every active project once per day and SHALL serve the cached
  snapshot to project-page requests.
  *Tests:* `spec/services/project_dashboard_metrics/snapshot_spec.rb`,
  `spec/jobs/project_dashboard_metrics_sweep_job_spec.rb`.
  *Code:* `app/services/project_dashboard_metrics/snapshot.rb`,
  `app/jobs/project_dashboard_metrics_sweep_job.rb`.

- [x] **PROJECT-DASHBOARD-METRICS-003** — When a metric has no authoritative
  source observations, the system SHALL display it as unavailable rather than
  reporting a zero average.
  *Tests:* `spec/services/project_dashboard_metrics/snapshot_spec.rb`.
  *Code:* `app/services/project_dashboard_metrics/snapshot.rb`,
  `app/views/projects/_dashboard_metrics.html.erb`.
