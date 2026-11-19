# EARS Specs: Observability Stack

> Testable claims for the shipped observability surfaces from RDR-011. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r OBSERVABILITY-001`).

- [x] **OBSERVABILITY-005** — When an operator starts development memory
  monitoring, its services SHALL run independently of Rails/PostgreSQL, retain
  metrics in a named volume for up to 14 days subject to a 2 GB size bound,
  declare CPU/memory limits and log rotation, and publish UI ports only on host
  loopback. Stopping monitoring SHALL preserve its stored history and SHALL NOT
  stop or recreate application services.
  *Tests:* `spec/config/development_memory_monitoring_spec.rb`.

- [x] **OBSERVABILITY-006** — Development memory monitoring SHALL scrape
  Docker-host VM memory/swap, individual container memory and limits, fixed
  host-wide Paid Puma/worker process groups, PostgreSQL activity, application
  job activity through a narrow read-only aggregate, and both devcontainer
  worker endpoints every 15 seconds. It SHALL NOT repeatedly invoke Rails'
  broad metrics collector or PostgreSQL database-size scans.
  Metrics SHALL NOT contain SQL text, credentials, or command lines as labels.
  Configuration delivery SHALL work from inside a devcontainer without assuming
  its repository path exists on the Docker daemon's host.
  *Tests:* `spec/config/development_memory_monitoring_spec.rb`.

- [x] **OBSERVABILITY-007** — The development memory dashboard SHALL show
  scrape coverage, memory, swap, OOM signals and container starts on a UTC
  timeline, retain unavailable series as unavailable, and distinguish OOM
  victims from attribution of host exhaustion. Operator documentation SHALL
  describe how to inspect the corresponding PgHero query interval and state
  measured exporter limitations.
  *Tests:* `spec/config/development_memory_monitoring_spec.rb`.

- [x] **OBSERVABILITY-008** — Development memory activation SHALL reject
  non-development environments before external mutation, generate owner-only
  local credential files, provision a non-superuser read-only PostgreSQL
  monitoring role, and seed runtime credentials without embedding them in
  image layers or command arguments. Activation SHALL NOT recreate the running
  application or delete monitoring volumes.
  *Tests:* `spec/config/development_memory_monitoring_spec.rb`.

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

- [x] **OBSERVABILITY-APP-DIAGNOSTICS-001** — When an authenticated run requests application
  diagnostics, Paid SHALL return only that run's retained verification log tail
  and run container samples, with account/project/run/revision/timestamp
  provenance and secret redaction. Container samples SHALL identify their
  subject as the agent container and SHALL NOT be represented as target-
  application telemetry. Redaction SHALL cover every active account credential
  the run could use, whatever its length; no minimum length may exempt a
  persisted credential from redaction, and short credentials SHALL be matched
  on delimiters so ordinary words remain intact.
  *Code:* `AgentRuns::ApplicationDiagnostics`,
  `AgentRuns::Research::SecretGuard`.
  *Test:* `spec/services/agent_runs/application_diagnostics_spec.rb`.

- [x] **OBSERVABILITY-APP-DIAGNOSTICS-002** — Diagnostic retrieval SHALL be read-only and
  bound lookback to one hour, samples to 100, and log content to 32 KiB; absent
  instrumentation SHALL be reported as unavailable evidence.
  *Code:* `AgentRuns::ApplicationDiagnostics`.
  *Test:* `spec/services/agent_runs/application_diagnostics_spec.rb`.

- [x] **OBSERVABILITY-APP-DIAGNOSTICS-003** — The run diagnostic endpoint SHALL authenticate
  with the existing container credential and SHALL not accept a target run,
  project, host, file, or container identifier.
  *Code:* `Api::ApplicationDiagnosticsController`.
  *Test:* `spec/requests/api/application_diagnostics_spec.rb`.

- [x] **OBSERVABILITY-APP-DIAGNOSTICS-004** — While an authenticated run is active and
  verification is in progress, Paid SHALL accept only that run's bounded
  application-log tail, redact it before persistence, and make the captured
  tail available through that run's diagnostic retrieval endpoint before the
  verification outcome is finalized. Capture requests SHALL be bounded per
  run to a fixed capture budget within a rolling window, rejecting excess
  captures with `429` rather than persisting them.
  *Code:* `Api::ApplicationDiagnosticsController`,
  `AgentRuns::CaptureApplicationLog`.
  *Test:* `spec/requests/api/application_diagnostics_spec.rb`.
