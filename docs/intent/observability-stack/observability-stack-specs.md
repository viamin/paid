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
  agent-run, GoodJob, agent-container, warm-pool, service-container, and
  Temporal-capacity metrics in Prometheus HELP/TYPE format and SHALL cache the
  rendered payload for 15 seconds.
  *Code:* `app/services/metrics/prometheus_collector.rb`.
  *Test:* `spec/services/metrics/prometheus_collector_spec.rb`.

- [x] **OBSERVABILITY-003** — The repository SHALL check in an observability
  overlay that wires Prometheus scraping/rules, Grafana provisioning, and
  Alertmanager routing around the shipped metric names.
  *Code:* `docker-compose.observability.yml`, `prometheus/prometheus.yml`,
  `prometheus/rules/paid.yml`, `grafana/provisioning/datasources/prometheus.yml`,
  `grafana/provisioning/dashboards/dashboards.yml`,
  `alertmanager/alertmanager.yml`.
  *Test:* `spec/config/checked_in_observability_assets_spec.rb`.
