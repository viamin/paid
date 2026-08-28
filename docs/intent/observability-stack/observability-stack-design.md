---
parent: PAID
prefix: OBSERVABILITY
---

# Low-Level Design: Observability Stack

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the current shipped observability surfaces from RDR-011:
> the Rails metrics endpoint, the application collector it exposes, the
> checked-in Prometheus/Grafana/Alertmanager assets that scrape and visualize
> those metrics, and the self-hosted log-aggregation path for Rails and worker
> processes.

## Purpose

Paid needs operational visibility into queue depth, active runs, worker
capacity, and container pressure without depending on ad hoc log scraping.
The shipped observability stack exposes Prometheus-compatible metrics from the
Rails app, publishes Temporal worker metrics separately, emits structured JSON
application logs to stdout, and checks in the infrastructure assets needed to
scrape, alert on, visualize, and search those signals.

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
- current terminal agent-run outcome gauges split by success/failure and status
- current completed agent-run duration bucket/sum/count aggregates
- current completed agent-run token totals
- current completed agent-run cost totals
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
  the shipped metric names, including application-level run failure-rate and
  long-duration alerts backed by collector-exported metrics.
- `grafana/provisioning/` and `grafana/dashboards/paid-overview.json`
  provision a Prometheus datasource and a default dashboard covering both stack
  health and application-level run outcomes, duration, token usage, and spend.
- `alertmanager/alertmanager.yml` provides the initial routing/inhibition
  configuration for those Prometheus alerts.

## Self-Hosted Log Aggregation

Paid's supported self-hosted logging path is Loki plus Promtail, aligned with
the existing Compose-based observability overlay instead of a separate
deployment shape.

- `docker-compose.observability.yml` starts `loki` and `promtail` behind the
  `observability` profile alongside Prometheus, Grafana, and Alertmanager.
- `loki/config.yml` provides the single-node filesystem-backed Loki
  configuration used by the overlay.
- `promtail/config.yml` discovers Docker containers through the Docker socket,
  unwraps Docker's outer log envelope, and labels entries with Compose metadata
  such as service and project.
- `grafana/provisioning/datasources/loki.yml` provisions the Loki datasource so
  operators can query logs in Grafana Explore next to the existing metrics
  datasource.

## Log Emission And Query Shape

The Compose `web` and `worker` services set `RAILS_LOG_TO_STDOUT=1` and
`PAID_LOG_FORMAT=json`, which selects the checked-in JSON formatter for Rails
and background-worker processes. That formatter keeps the existing structured
`Rails.logger.info(message: ..., **metadata)` call sites as the source of truth
and serializes them as one JSON object per line with a stable top-level shape:

- `timestamp`
- `level`
- `message`
- `request_id` when a request tag is present
- any structured metadata fields passed by the caller, such as `agent_run_id`,
  `project_id`, `workflow_id`, or `job_id`

Promtail intentionally promotes low-cardinality routing metadata to labels
(`job`, `source`, `compose_project`, and `compose_service`) and also records
the current container name for troubleshooting. High-cardinality correlation
fields remain in the JSON payload so operators can query them with LogQL
`| json` filters without exploding label cardinality.

## Durable per-run failure detail vs. process logs

The JSON process-log stream above is complete but not durable across log
rotation, and it is not queryable per run once it has scrolled off. For
failures a specific `agent_run` needs to remain diagnosable for (e.g. per-LLM-
provider failures during `analyze_issue`, see `docs/intent/issue-analysis/`
`ISSUE-ANALYSIS-013`), the run itself persists a structured, redacted
`AgentRunLog` entry alongside the process-log line, so the detail survives
rotation and is groupable by a normalized category rather than free-text
messages. The structured JSON log line remains the source of truth for live
tailing/alerting; the `AgentRunLog` entry is the durable, run-scoped
counterpart — neither replaces the other.

## What this is not

- **Not a raw `prometheus-client` middleware install.** The current app uses a
  custom collector rather than the original draft's in-process metric objects.
- **Not a log-only monitoring story.** Structured logs complement this stack
  but do not replace the scrapeable metrics/alerts/dashboard path.
- **Not a single-process metrics source.** Temporal worker runtime metrics are
  scraped separately from the Rails `/api/metrics` endpoint.
