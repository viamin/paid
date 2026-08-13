# RDR-011 Closeout Audit - 2026-08-05

## Scope

Close out `RDR-011: Observability Stack` against the shipped implementation and decide whether any original goals still block the RDR from being marked implemented.

Related issue: [#3173](https://github.com/viamin/paid/issues/3173)

## Sources Reviewed

- [RDR-011-observability.md](./RDR-011-observability.md)
- [docs/METRICS.md](../METRICS.md)
- [docs/OBSERVABILITY.md](../OBSERVABILITY.md)
- [docker-compose.observability.yml](../../docker-compose.observability.yml)
- [prometheus/prometheus.yml](../../prometheus/prometheus.yml)
- [prometheus/rules/paid.yml](../../prometheus/rules/paid.yml)
- [grafana/provisioning/dashboards/dashboards.yml](../../grafana/provisioning/dashboards/dashboards.yml)
- [grafana/dashboards/paid-overview.json](../../grafana/dashboards/paid-overview.json)
- [alertmanager/alertmanager.yml](../../alertmanager/alertmanager.yml)
- [app/controllers/api/metrics_controller.rb](../../app/controllers/api/metrics_controller.rb)
- [app/services/metrics/prometheus_collector.rb](../../app/services/metrics/prometheus_collector.rb)
- [spec/config/observability_assets_spec.rb](../../spec/config/observability_assets_spec.rb)
- [spec/requests/api/metrics_spec.rb](../../spec/requests/api/metrics_spec.rb)
- [spec/services/metrics/prometheus_collector_spec.rb](../../spec/services/metrics/prometheus_collector_spec.rb)

## Findings

### Shipped and Verified

- Rails exports Prometheus text exposition at `/api/metrics` through `Api::MetricsController`.
- `Metrics::PrometheusCollector` is the shipped Rails metrics source of truth.
- Prometheus, Grafana, Alertmanager, `postgres-exporter`, `node-exporter`, and `cadvisor` are checked in through `docker-compose.observability.yml`.
- Prometheus scrape config and alert rules are checked in and covered by tests.
- Grafana datasource/dashboard provisioning is checked in and covered by tests.
- Alertmanager routing is checked in with a safe default receiver.
- Temporal worker telemetry is exported through Temporal's native Prometheus exporter rather than through the Rails collector.

### Superseded or Reduced from the Original RDR Sketch

- The original `prometheus-client` middleware/counter/histogram example was superseded by the hand-rolled collector design and is no longer the implementation target.
- The original dashboard/alerting examples were reduced to match shipped metrics instead of inventing alerts for metrics that do not exist.
- The current dashboard and alerts focus on stack health, queue backlog, Temporal saturation/latency, and container memory pressure. That is sufficient to treat the observability stack decision itself as implemented.

### Real Remaining Gaps

- Higher-level application Prometheus instrumentation for run outcomes, duration, token usage, and cost/spend is still missing. Tracked by [#3238](https://github.com/viamin/paid/issues/3238).
- Centralized structured log aggregation is still only planned in docs and has no shipped deployment/config assets. Tracked by [#3239](https://github.com/viamin/paid/issues/3239).

## Decision

`RDR-011` should be marked **Implemented**.

Rationale:

- The core architectural decision was to adopt a self-hosted Prometheus/Grafana/Alertmanager observability stack for Paid.
- That stack is now present in the repository, wired to real metric sources, and backed by request/spec coverage.
- The remaining work is follow-up enhancement scope, not evidence that the observability stack decision failed to ship.
- Those remaining gaps are now represented by focused active issues instead of being left as ambiguous implied work under the RDR.

## Status Update Required

- Update `docs/rdrs/RDR-011-observability.md` to `Implemented`
- Update `docs/rdrs/README.md` to `Implemented`

## Follow-up Issues

- [#3238](https://github.com/viamin/paid/issues/3238) `observability: add application-level Prometheus metrics for run outcomes, duration, tokens, and cost`
- [#3239](https://github.com/viamin/paid/issues/3239) `observability: ship centralized structured log aggregation for Rails and worker processes`
