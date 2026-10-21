# EARS Specs: Observability Stack

> Testable claims for the shipped observability surfaces from RDR-011. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r OBSERVABILITY-001`).

- [x] **OBSERVABILITY-001** — When a client requests `GET /api/metrics`, the
  Rails app SHALL return Prometheus text exposition from the application
  collector and SHALL require a bearer token only when `METRICS_TOKEN` is set.
  *Code:* `app/controllers/api/metrics_controller.rb`.
  *Test:* `spec/requests/api/metrics_spec.rb`.

- [x] **OBSERVABILITY-002** — The application metrics collector SHALL expose
  agent-run status gauges, snapshot gauges for terminal run outcomes,
  run-duration bucket/sum/count aggregates, token/cost totals, GoodJob,
  agent-container, warm-pool, service-container, and Temporal-capacity
  metrics in Prometheus HELP/TYPE format and SHALL cache the rendered payload
  for 15 seconds.
  *Code:* `app/services/metrics/prometheus_collector.rb`.
  *Test:* `spec/services/metrics/prometheus_collector_spec.rb`.

- [x] **OBSERVABILITY-003** — The repository SHALL check in an observability
  overlay that wires Prometheus scraping/rules, Grafana provisioning, and
  Alertmanager routing around the shipped metric names, including application-
  level run outcome and duration views/alerts only when those metrics are
  exported by the collector.
  *Code:* `docker-compose.observability.yml`, `prometheus/prometheus.yml`,
  `prometheus/rules/paid.yml`, `grafana/provisioning/datasources/prometheus.yml`,
  `grafana/provisioning/dashboards/dashboards.yml`,
  `alertmanager/alertmanager.yml`.
  *Test:* `spec/config/checked_in_observability_assets_spec.rb`.

- [x] **OBSERVABILITY-004** — The repository SHALL ship a supported self-hosted
  log aggregation path that emits Rails and worker logs as structured JSON to
  stdout, collects Docker logs with Promtail, stores them in Loki, and
  provisions Grafana with a Loki datasource plus stable service labels for
  querying.
  *Code:* `lib/paid/json_log_formatter.rb`,
  `config/initializers/structured_logging.rb`, `docker-compose.yml`,
  `docker-compose.observability.yml`, `loki/config.yml`, `promtail/config.yml`,
  `grafana/provisioning/datasources/loki.yml`.
  *Test:* `spec/lib/paid/json_log_formatter_spec.rb`,
  `spec/config/checked_in_observability_assets_spec.rb`.

- [x] **APP-DIAGNOSTICS-001** — When an authenticated run requests application
  diagnostics, Paid SHALL return only that run's retained verification log tail
  and run container samples, with account/project/run/revision/timestamp
  provenance and secret redaction.
  *Code:* `AgentRuns::ApplicationDiagnostics`.
  *Test:* `spec/services/agent_runs/application_diagnostics_spec.rb`.

- [x] **APP-DIAGNOSTICS-002** — Diagnostic retrieval SHALL be read-only and
  bound lookback to one hour, samples to 100, and log content to 32 KiB; absent
  instrumentation SHALL be reported as unavailable evidence.
  *Code:* `AgentRuns::ApplicationDiagnostics`.
  *Test:* `spec/services/agent_runs/application_diagnostics_spec.rb`.

- [x] **APP-DIAGNOSTICS-003** — The run diagnostic endpoint SHALL authenticate
  with the existing container credential and SHALL not accept a target run,
  project, host, file, or container identifier.
  *Code:* `Api::ApplicationDiagnosticsController`.

- [x] **APP-DIAGNOSTICS-004** — While an authenticated run is active and
  verification is in progress, Paid SHALL accept only that run's bounded
  application-log tail, redact it before persistence, and make the captured
  tail available through that run's diagnostic retrieval endpoint before the
  verification outcome is finalized.
  *Code:* `Api::ApplicationDiagnosticsController`,
  `AgentRuns::CaptureApplicationLog`.
  *Test:* `spec/requests/api/application_diagnostics_spec.rb`.
