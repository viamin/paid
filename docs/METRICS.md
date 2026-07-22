# Prometheus Metrics Reference

Paid exports worker and infrastructure metrics at `GET /api/metrics` in Prometheus text exposition format (`text/plain; version=0.0.4`). Authentication is optional: when `METRICS_TOKEN` is set, scrapers must send `Authorization: Bearer <token>`; when unset, the endpoint is unauthenticated and should be network-isolated (VPC-internal only).

Temporal SDK worker metrics are exported separately by `bin/temporal_worker` on `TEMPORAL_PROMETHEUS_BIND_ADDRESS` (default `0.0.0.0:9464`). That endpoint includes built-in Temporal queue latency/retry/saturation metrics plus Paid's replay-safe workflow counter `temporal_paid_swallowed_non_critical_activity_failures_total`.

The checked-in observability stack assets use that split explicitly:

- `prometheus/prometheus.yml` scrapes `web:3000/api/metrics`
- `prometheus/prometheus.yml` scrapes `worker:9464` for Temporal SDK metrics
- `docker-compose.observability.yml` provisions Prometheus, Grafana, Alertmanager, `postgres-exporter`, `node-exporter`, and `cadvisor`

## Agent Run Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_agent_runs_total` | gauge | `status` | Number of agent runs by status (queued, pending, running, completed, failed, etc.) |
| `paid_agent_runs_active` | gauge | — | Currently active agent runs (pending + running) |
| `paid_agent_runs_queued` | gauge | — | Agent runs waiting in queue |

## GoodJob Queue Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_goodjob_queue_depth` | gauge | `queue` | Unfinished jobs per queue (default, maintenance, metrics, knowledge, low_priority) |
| `paid_goodjob_jobs_unfinished` | gauge | — | Total unfinished GoodJob jobs across all queues |
| `paid_goodjob_jobs_running` | gauge | — | Jobs currently being executed |
| `paid_goodjob_jobs_errored` | gauge | — | Jobs in error state (will be retried) |

## Container Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_containers_active` | gauge | — | Distinct containers currently running agent work |
| `paid_containers_avg_cpu_percent` | gauge | — | Average CPU usage across active containers (0–100) |
| `paid_containers_avg_memory_percent` | gauge | — | Average memory usage across active containers (0–100) |
| `paid_containers_total_memory_bytes` | gauge | — | Total memory bytes consumed by active containers |

Container resource metrics (CPU, memory) are derived from the most recent sample per container within a 5-minute window. They are only present when at least one active container has recorded metrics.

## Container Pool Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_container_pool_entries_total` | gauge | `status` | Warm container pool entries by status |
| `paid_container_pool_target` | gauge | — | Target pool size for warm containers |

## Service Container Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_service_containers_total` | gauge | `status` | Service containers by status (stopped, starting, running, error) |
| `paid_service_containers_avg_cpu_percent` | gauge | — | Average CPU across running service containers |
| `paid_service_containers_avg_memory_percent` | gauge | — | Average memory across running service containers |

## Temporal Worker Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `paid_temporal_workflow_slots_total` | gauge | — | Configured workflow slot capacity (`TEMPORAL_WORKFLOW_SLOTS`, default 20) |
| `paid_temporal_activity_slots_total` | gauge | — | Configured activity slot capacity (`TEMPORAL_ACTIVITY_SLOTS`, default 4) |
| `paid_temporal_workflows_running` | gauge | — | Temporal workflows currently in-flight |
| `paid_temporal_workflow_utilization_percent` | gauge | — | Workflow slot utilization (running / total × 100) |

## Scrape Configuration

Example Prometheus `scrape_configs` entry (matches the checked-in `prometheus/prometheus.yml`):

```yaml
scrape_configs:
  - job_name: paid
    scrape_interval: 30s
    metrics_path: /api/metrics
    # Optional Bearer auth. When METRICS_TOKEN is set on the Rails app, the
    # scraper must include `Authorization: Bearer <token>`. The token value
    # is read from this file at scrape time; docker-compose.observability.yml
    # wires the file path to the host's METRICS_TOKEN via a `secrets:` mount.
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/metrics_token
    static_configs:
      - targets: ["paid-host:3000"]
  - job_name: paid-temporal-worker
    static_configs:
      - targets: ['temporal-worker:9464']
```

### Recommended dashboard queries

- Workflow task queue `schedule_to_start` p95 by task queue:
  `histogram_quantile(0.95, sum by (task_queue, le) (rate(temporal_workflow_task_schedule_to_start_latency_seconds_bucket[5m])))`
- Activity task queue `schedule_to_start` p95 by task queue:
  `histogram_quantile(0.95, sum by (task_queue, le) (rate(temporal_activity_schedule_to_start_latency_seconds_bucket[5m])))`
- Swallowed exhausted-retry poller failures:
  `sum by (helper, task_queue) (rate(temporal_paid_swallowed_non_critical_activity_failures_total[15m]))`

## Scaling Signals

Recommended auto-scaling signals:

- **Scale up workers** when `paid_temporal_workflow_utilization_percent > 80` or `paid_agent_runs_queued > 5`
- **Scale up containers** when `paid_containers_avg_cpu_percent > 75` or `paid_containers_avg_memory_percent > 80`
- **Scale down** when `paid_temporal_workflow_utilization_percent < 20` and `paid_agent_runs_queued == 0`
- **Alert on queue backlog** when `paid_goodjob_queue_depth{queue="default"} > 50`

## Collector Design

The original observability RDR proposed adopting the `prometheus-client` Ruby gem. Paid instead ships a hand-rolled collector in `Metrics::PrometheusCollector`, and the checked-in Prometheus rules and Grafana dashboards now target that collector as the source of truth.

That design choice has a direct consequence: some example metrics from the original RDR, such as cost counters or quality-score histograms, do not exist yet and therefore are not referenced by the shipped alert rules or dashboard panels. If Paid later adds counter or histogram-style instrumentation, those assets can be expanded without changing the deployment shape.
