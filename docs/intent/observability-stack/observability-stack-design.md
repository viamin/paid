---
parent: PAID
prefix: OBSERVABILITY
---

# Low-Level Design: Observability Stack

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the current shipped observability surfaces from RDR-011:
> the Rails metrics endpoint, the application collector it exposes, and the
> checked-in Prometheus/Grafana/Alertmanager assets that scrape and visualize
> those metrics.

## Purpose

Paid needs operational visibility into queue depth, active runs, worker
capacity, and container pressure without depending on ad hoc log scraping.
The shipped observability stack exposes Prometheus-compatible metrics from the
Rails app, publishes Temporal worker metrics separately, and checks in the
infrastructure assets needed to scrape, alert on, and visualize those signals.

## Rails Metrics Surface

`Api::MetricsController#show` serves `GET /api/metrics` with Prometheus text
exposition (`text/plain; version=0.0.4`). The endpoint is intentionally
unauthenticated when `METRICS_TOKEN` is unset so private-network scrapers can
read it directly; when `METRICS_TOKEN` is present, scrapers must send
`Authorization: Bearer <token>`.

The response body comes from `Metrics::PrometheusCollector.call`. The collector
is cached in `Rails.cache` for 15 seconds to bound the query load from frequent
scrapes while keeping the data fresh enough for dashboards and alerts.

## Application Collector

`Metrics::PrometheusCollector` is the Rails-side source of truth for current
application metrics. It emits:

- agent-run status counts plus active and queued totals
- unfinished/running/errored GoodJob queue depth
- active agent-container counts plus recent CPU and memory aggregates
- warm container-pool counts and effective target size
- service-container counts plus recent CPU and memory aggregates
- configured Temporal workflow/activity slot counts, running workflows, and
  workflow-slot utilization

The collector renders Prometheus HELP/TYPE headers together with the sample
lines, so the endpoint is scrape-ready without a separate metrics library.

## Checked-in Observability Assets

The repo also checks in the observability overlay and provisioning assets:

- `docker-compose.observability.yml` starts Prometheus, Grafana, Alertmanager,
  postgres-exporter, node-exporter, and cAdvisor behind the `observability`
  profile.
- `prometheus/prometheus.yml` scrapes the Rails `/api/metrics` endpoint, the
  Temporal worker exporter, postgres-exporter, node-exporter, and cAdvisor.
- `prometheus/rules/paid.yml` defines availability and capacity alerts against
  the shipped metric names.
- `grafana/provisioning/` and `grafana/dashboards/paid-overview.json`
  provision a Prometheus datasource and a default dashboard.
- `alertmanager/alertmanager.yml` provides the initial routing/inhibition
  configuration for those Prometheus alerts.

## What this is not

- **Not a raw `prometheus-client` middleware install.** The current app uses a
  custom collector rather than the original draft's in-process metric objects.
- **Not a log-only monitoring story.** Structured logs complement this stack
  but do not replace the scrapeable metrics/alerts/dashboard path.
- **Not a single-process metrics source.** Temporal worker runtime metrics are
  scraped separately from the Rails `/api/metrics` endpoint.
