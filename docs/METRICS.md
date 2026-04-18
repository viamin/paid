# Prometheus Metrics Reference

Paid exports worker and infrastructure metrics at `GET /api/metrics` in Prometheus text exposition format (`text/plain; version=0.0.4`). Authentication is optional: when `METRICS_TOKEN` is set, scrapers must send `Authorization: Bearer <token>`; when unset, the endpoint is unauthenticated and should be network-isolated (VPC-internal only).

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

Example Prometheus `scrape_configs` entry:

```yaml
scrape_configs:
  - job_name: paid
    scrape_interval: 30s
    metrics_path: /api/metrics
    static_configs:
      - targets: ["paid-host:3000"]
```

## Scaling Signals

Recommended auto-scaling signals:

- **Scale up workers** when `paid_temporal_workflow_utilization_percent > 80` or `paid_agent_runs_queued > 5`
- **Scale up containers** when `paid_containers_avg_cpu_percent > 75` or `paid_containers_avg_memory_percent > 80`
- **Scale down** when `paid_temporal_workflow_utilization_percent < 20` and `paid_agent_runs_queued == 0`
- **Alert on queue backlog** when `paid_goodjob_queue_depth{queue="default"} > 50`
