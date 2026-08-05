# Paid Observability

## Implementation Status

Sections marked **[IMPLEMENTED]** reflect the current codebase. Sections marked **[PLANNED]** describe future architecture that has not been built yet.

This document describes the observability strategy for Paid, covering metrics collection, logging, dashboards, and alerting.

## Overview

Observability in Paid has three pillars:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OBSERVABILITY PILLARS                                │
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │     METRICS     │  │      LOGS       │  │     TRACES      │             │
│  │   (Prometheus)  │  │   (Structured)  │  │   (Temporal)    │             │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘             │
│           │                    │                    │                       │
│           ▼                    ▼                    ▼                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                          GRAFANA                                        ││
│  │              Unified dashboards for all telemetry                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Metrics (Prometheus) [IMPLEMENTED]

### Stack

| Component | Purpose |
|-----------|---------|
| Prometheus | Time-series metrics storage and alerting |
| `Metrics::PrometheusCollector` | Hand-rolled Ruby metrics exposition (`app/services/metrics/prometheus_collector.rb`) |
| Temporal metrics | Workflow and activity metrics |

The original RDR sketched a `prometheus-client` gem integration, but the implementation that shipped uses a hand-rolled collector instead. That is now the authoritative design: Paid exports a Prometheus-compatible snapshot of database-backed operational state from `Metrics::PrometheusCollector`, while Temporal worker runtime metrics continue to come from Temporal's native Prometheus exporter.

### Metrics Definitions [IMPLEMENTED]

Metrics are defined in `Metrics::PrometheusCollector` and rendered in Prometheus text exposition format. The collector queries the database directly and caches results for 15 seconds.

#### Agent Run Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_agent_runs_total` | gauge | Number of agent runs by status |
| `paid_agent_runs_active` | gauge | Currently active agent runs |
| `paid_agent_runs_queued` | gauge | Agent runs waiting in queue |
| `paid_agent_run_outcomes_window` | gauge | Finished runs in the last 6h by terminal status and normalized outcome. Sliding-window snapshot. |
| `paid_agent_run_duration_seconds_bucket_window` | gauge | Finished run duration bucket counts in the last 6h. Sliding-window snapshot; not a cumulative Prometheus histogram. |
| `paid_agent_run_duration_seconds_sum_window` | gauge | Total finished run duration in seconds in the last 6h. Sliding-window snapshot. |
| `paid_agent_run_duration_seconds_count_window` | gauge | Number of finished runs with duration samples in the last 6h. Sliding-window snapshot. |
| `paid_agent_run_tokens_window` | gauge | Finished-run tokens in the last 6h by direction and normalized outcome. Sliding-window snapshot. |
| `paid_agent_run_cost_cents_window` | gauge | Finished-run cost in cents in the last 6h by normalized outcome. Sliding-window snapshot. |

#### GoodJob Queue Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_goodjob_queue_depth` | gauge | Unfinished jobs per queue |
| `paid_goodjob_jobs_unfinished` | gauge | Total unfinished GoodJob jobs |
| `paid_goodjob_jobs_running` | gauge | GoodJob jobs currently executing |
| `paid_goodjob_jobs_errored` | gauge | GoodJob jobs in error state |

#### Container Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_containers_active` | gauge | Containers running agent work |
| `paid_containers_avg_cpu_percent` | gauge | Average CPU usage across active containers |
| `paid_containers_avg_memory_percent` | gauge | Average memory usage across active containers |
| `paid_containers_total_memory_bytes` | gauge | Total memory used by active containers |

#### Container Pool Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_container_pool_entries_total` | gauge | Warm container pool entries by status |
| `paid_container_pool_target` | gauge | Target warm container pool size |

#### Service Container Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_service_containers_total` | gauge | Service containers by status |
| `paid_service_containers_avg_cpu_percent` | gauge | Average CPU across running service containers |
| `paid_service_containers_avg_memory_percent` | gauge | Average memory across running service containers |

#### Temporal Configuration Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_temporal_workflow_slots_total` | gauge | Configured Temporal workflow slots |
| `paid_temporal_activity_slots_total` | gauge | Configured Temporal activity slots |
| `paid_temporal_workflows_running` | gauge | Temporal workflows currently running |
| `paid_temporal_workflow_utilization_percent` | gauge | Workflow slot utilization percentage |

### Metrics Exposition [IMPLEMENTED]

```ruby
# config/routes.rb
Rails.application.routes.draw do
  namespace :api do
    get 'metrics', to: 'metrics#show'
  end
end

# app/controllers/api/metrics_controller.rb
class Api::MetricsController < ActionController::API
  before_action :authenticate_metrics_token!, if: -> { ENV["METRICS_TOKEN"].present? }

  def show
    render plain: Metrics::PrometheusCollector.call,
           content_type: "text/plain; version=0.0.4; charset=utf-8"
  end

  private

  def authenticate_metrics_token!
    provided = request.authorization&.delete_prefix("Bearer ")
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided.to_s, ENV["METRICS_TOKEN"])
  end
end
```

Authentication uses a `METRICS_TOKEN` bearer token. When the `METRICS_TOKEN` environment variable is set, scrapers must send `Authorization: Bearer <token>`. If `METRICS_TOKEN` is not set, the endpoint is unauthenticated (intended for VPC-internal use only).

The checked-in `prometheus/prometheus.yml` reads the token from `/etc/prometheus/metrics_token` via the `authorization.credentials_file` field on the `paid` scrape job. The file is mounted by `docker-compose.observability.yml` from the host path `${METRICS_TOKEN_FILE:-./tmp/prometheus/metrics_token}`. The default location lives under `./tmp/` (gitignored) so a live token never lands in the tracked working tree. `bin/setup` writes the value of the host's `METRICS_TOKEN` environment variable into that file when `METRICS_TOKEN` is present in the current process environment, and creates an empty file when it is absent (so `docker compose --profile observability up` can start on a fresh checkout). When `METRICS_TOKEN` is absent, `bin/setup` leaves any pre-existing token content untouched so helper processes do not clobber a token that a separate bootstrap path already materialized. With the default empty file, Prometheus sends a blank `Bearer` header and the Rails side skips its token check.

### Prometheus Configuration [IMPLEMENTED]

```yaml
# prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # Paid Rails app
  - job_name: 'paid'
    static_configs:
      - targets: ['web:3000']
    metrics_path: '/api/metrics'
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/metrics_token

  # Temporal SDK worker metrics
  - job_name: 'paid-temporal-worker'
    static_configs:
      - targets: ['worker:9464']

  # PostgreSQL (via postgres_exporter)
  - job_name: 'postgresql'
    static_configs:
      - targets: ['postgres-exporter:9187']

  # Docker containers (via cadvisor)
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
```

---

## Logging [IMPLEMENTED]

### Log Format

Paid uses Rails `ActiveSupport::TaggedLogging` with `config.log_tags = [:request_id]` in the default app configuration. For the supported self-hosted Compose deployment path, the `web` and `worker` services also set `PAID_LOG_FORMAT=json` and `RAILS_LOG_TO_STDOUT=1`, so the structured `Rails.logger.info(message: ..., **metadata)` calls already used across the codebase are emitted as newline-delimited JSON to container stdout, with `request_id` lifted directly from `Current.request_id` when present.

```ruby
# config/application.rb (or environment config)
config.log_tags = [:request_id]
```

### Correlation IDs

`Current.request_id` (provided by Rails) is used for correlation within a request. There is no custom `RequestIdMiddleware` — Rails sets `request_id` automatically via `ActionDispatch::RequestId`.

### Log Aggregation [IMPLEMENTED]

Self-hosted Paid ships Loki + Promtail as the supported centralized log path:

```yaml
# docker-compose.observability.yml
services:
  loki:
    image: grafana/loki:3.1.1
    volumes:
      - ./loki:/etc/loki:ro
      - loki-data:/loki

  promtail:
    image: grafana/promtail:3.1.1
    volumes:
      - ./promtail:/etc/promtail:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: -config.file=/etc/promtail/config.yml
```

Promtail discovers Docker containers through the Docker socket, unwraps
Docker's outer log envelope, and forwards the underlying JSON log lines to
Loki. Grafana provisions both the Prometheus and Loki datasources, so operators
can use Grafana Explore for log search while keeping the existing dashboards
for metrics and alerts.

### Stable Labels And Correlation Fields

Promtail promotes the stable routing metadata below to Loki labels and also
adds the current container name for troubleshooting:

| Label | Meaning |
|-------|---------|
| `job` | Promtail scrape job (`docker`) |
| `source` | Log source (`docker`) |
| `compose_project` | Docker Compose project name |
| `compose_service` | Stable service name such as `web` or `worker` |

High-cardinality fields remain in the JSON payload instead of becoming labels.
That includes correlation keys such as `request_id`, `agent_run_id`,
`project_id`, `workflow_id`, `job_id`, and `chat_session_id`.

### Querying Rails And Worker Logs

Use Grafana Explore with the `Loki` datasource.

- Rails request logs:
  `{compose_service="web"} | json | request_id="abc-123"`
- Worker activity for a single agent run:
  `{compose_service="worker"} | json | agent_run_id=12345`
- All container-manager events across web and worker:
  `{compose_service=~"web|worker"} | json | message=~"container_manager\\..*"`
- Rails + worker correlation by project:
  `{compose_service=~"web|worker"} | json | project_id=42`

The supported pattern is: use labels to bound the stream first, then `| json`
to filter on request/run/workflow fields inside the log body.

---

## Temporal Observability

Temporal provides built-in observability for workflows:

### Temporal Metrics

Temporal exposes Prometheus metrics on port 8000:

- `temporal_workflow_task_schedule_to_start_latency`
- `temporal_activity_schedule_to_start_latency`
- `temporal_workflow_completed`
- `temporal_workflow_failed`
- `temporal_activity_execution_failed`

### Temporal UI

The Temporal UI (port 8080) provides:

- Workflow execution history
- Activity timing breakdown
- Error details and stack traces
- Workflow search and filtering

### Custom Workflow Metrics [PLANNED]

```ruby
# app/workflows/concerns/observable.rb [PLANNED]
module Observable
  extend ActiveSupport::Concern

  def record_workflow_started
    ACTIVE_WORKFLOWS.increment(labels: { workflow_type: self.class.name })
    Rails.logger.info(
      message: "workflow.started",
      workflow_type: self.class.name,
      workflow_id: workflow_id
    )
  end

  def record_workflow_completed(result)
    ACTIVE_WORKFLOWS.decrement(labels: { workflow_type: self.class.name })
    Rails.logger.info(
      message: "workflow.completed",
      workflow_type: self.class.name,
      workflow_id: workflow_id,
      result: result
    )
  end
end
```

---

## Dashboards (Grafana) [IMPLEMENTED]

Grafana provisioning and a starter dashboard are checked in under:

- `grafana/provisioning/datasources/prometheus.yml`
- `grafana/provisioning/dashboards/dashboards.yml`
- `grafana/dashboards/paid-overview.json`

The dashboard intentionally uses only metrics that exist today:

- Agent run active/queued gauges
- GoodJob backlog gauges
- Temporal workflow utilization gauges
- Container and service-container resource gauges
- Temporal SDK `schedule_to_start` latency histograms

### Dashboard Structure

```
Paid Dashboards/
├── Overview              # High-level system health
├── Agent Runs            # Agent execution details
├── Costs & Usage         # Token usage and costs
├── Quality               # Prompt performance, A/B tests
├── Infrastructure        # Containers, disk, GitHub API
└── Alerts                # Active alerts and history
```

### Overview Dashboard

Panels:

- **Active Workflows** (gauge): Current running workflows by type
- **Agent Runs (24h)** (stat): Total runs, success rate, avg duration
- **Token Usage (24h)** (stat): Total tokens, cost
- **PR Merge Rate** (gauge): Rolling 7-day merge rate
- **System Health** (status): Rails, Temporal, PostgreSQL, Docker

### Agent Runs Dashboard

Panels:

- **Runs Over Time** (time series): Runs by status (success/fail/timeout)
- **Duration Distribution** (heatmap): Run duration by agent type
- **Iterations Distribution** (histogram): Iterations to complete
- **Active Containers** (gauge): Current container count
- **Recent Failures** (table): Last 10 failed runs with error

### Costs Dashboard

Panels:

- **Daily Cost** (time series): Cost trend over time
- **Cost by Project** (pie chart): Cost distribution
- **Cost by Model** (bar chart): Model cost comparison
- **Token Usage** (time series): Input vs output tokens
- **Budget Utilization** (gauge): Per-project budget usage

### Quality Dashboard

Panels:

- **Quality Score Trend** (time series): Average quality over time
- **Quality by Prompt** (table): Per-prompt quality scores
- **A/B Test Results** (table): Active tests with variant performance
- **Human Feedback** (time series): Thumbs up/down trend
- **PR Outcomes** (pie chart): Merged vs closed vs pending

### Infrastructure Dashboard

Panels:

- **Container Metrics** (time series): CPU, memory per container
- **Disk Usage** (gauge): Repos, worktrees, logs, images
- **GitHub Rate Limits** (gauge): Remaining calls per token
- **Database Connections** (gauge): Active connections
- **Temporal Queue Depth** (time series): Pending workflows/activities

---

## Alerting [IMPLEMENTED]

### Alert Rules [IMPLEMENTED]

```yaml
# prometheus/rules/paid.yml
groups:
  - name: paid
    rules:
      - alert: PaidMetricsEndpointDown
        expr: up{job="paid"} == 0
      - alert: PaidQueuedRunsBacklog
        expr: paid_agent_runs_queued > 10
      - alert: PaidGoodJobBacklog
        expr: sum(paid_goodjob_queue_depth) > 50
      - alert: PaidTemporalWorkflowSlotsSaturated
        expr: paid_temporal_workflow_utilization_percent > 90
```

The shipped rules are constrained to metrics that Paid currently exports. Older examples in this document that referenced `paid_cost_cents_total`, `paid_quality_score`, or other unimplemented counters/histograms were removed to avoid publishing broken alert expressions.

### Alert Routing [IMPLEMENTED]

```yaml
# alertmanager/alertmanager.yml
route:
  receiver: 'null'
  group_by: ['alertname', 'severity', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - matchers:
        - severity="critical"
      receiver: 'null'

receivers:
  - name: 'null'
```

The checked-in Alertmanager config is intentionally safe by default: it groups and classifies alerts but routes them to a no-op receiver until an operator replaces that receiver with Slack, PagerDuty, or another destination appropriate to the deployment.

---

## Resource Cleanup [IMPLEMENTED]

### Worktree Cleanup Strategy

Worktrees consume disk space and must be cleaned up after use. Orphaned worktrees are cleaned up periodically by `WorktreeOrphanCleanupJob`:

```ruby
# app/jobs/worktree_orphan_cleanup_job.rb
class WorktreeOrphanCleanupJob < ApplicationJob
  # Cleanup triggers:
  # 1. Immediately after PR created (success path)
  # 2. Immediately after agent failure (failure path)
  # 3. Periodically for orphaned worktrees (this job)

  ORPHAN_THRESHOLD = 24.hours

  def perform
    # ... cleans up worktrees older than ORPHAN_THRESHOLD
    # that have no active agent runs
  end
end
```

### Container Cleanup

Orphaned Docker containers are cleaned up by `DockerOrphanCleanupJob`:

```ruby
# app/jobs/docker_orphan_cleanup_job.rb
class DockerOrphanCleanupJob < ApplicationJob
  def perform
    # ... finds Docker containers not tracked in the database
    # and removes them
  end
end
```

### Scheduled Cleanup Jobs

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.enable_cron = true
  config.good_job.cron = {
    worktree_cleanup: {
      cron: "0 */6 * * *",
      class: "WorktreeOrphanCleanupJob"
    },
    container_cleanup: {
      cron: "*/30 * * * *",
      class: "DockerOrphanCleanupJob"
    }
  }
end
```

---

## Docker Compose (Observability Stack) [IMPLEMENTED]

```yaml
# docker-compose.observability.yml
services:
  prometheus:
    profiles: ["observability"]

  grafana:
    profiles: ["observability"]

  alertmanager:
    profiles: ["observability"]

  cadvisor:
    profiles: ["observability"]

  postgres-exporter:
    profiles: ["observability"]

  node-exporter:
    profiles: ["observability"]

volumes:
  prometheus-data:
  grafana-data:
```

Bring the stack up as an overlay on top of the normal development environment:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml --profile observability up -d
```

Notes:

- The overlay scrapes the Rails app (`web:3000`) and Temporal SDK worker (`worker:9464`) because those are the metrics endpoints Paid exports today.
- Temporal server metrics are not included here because the current Compose topology does not enable a dedicated Prometheus listener on the Temporal server container.
- The `paid` scrape job reads its Bearer token from `/etc/prometheus/metrics_token` (a `secrets:` mount of the host file at `${METRICS_TOKEN_FILE:-./tmp/prometheus/metrics_token}`). `bin/setup` materializes this file from the host's `METRICS_TOKEN` environment variable when that variable is present in the current process environment, and creates an empty file when it is absent (so `docker compose --profile observability up` can start on a fresh checkout). The default path lives under `./tmp/` so a live token never lands in the tracked working tree. The `web` service propagates `METRICS_TOKEN` into the Rails container so the two stay in sync; when `METRICS_TOKEN` is absent, helper processes leave the existing token file untouched, and the Rails side accepts the scrape because its auth check is gated on `ENV["METRICS_TOKEN"].present?`.
- Loki/Promtail are now part of the checked-in self-hosted observability path for Compose deployments.

---

## Health Checks [IMPLEMENTED]

```ruby
# app/controllers/health_controller.rb
class HealthController < ActionController::Base
  # GET /health/services — Qdrant service health
  def show
    qdrant_healthy = begin
      Paid.qdrant_client.healthy?
    rescue StandardError
      false
    end

    status = qdrant_healthy ? :ok : :service_unavailable
    render json: {
      status: qdrant_healthy ? "ok" : "degraded",
      services: { qdrant: qdrant_healthy ? "ok" : "unavailable" }
    }, status: status
  end

  # GET /health/liveness — always returns 200 if Rails process is up
  def liveness
    render json: { status: "alive" }, status: :ok
  end

  # GET /health/readiness — checks database connectivity and pending migrations
  def readiness
    checks = {
      database: database_healthy?,
      migrations: migrations_current?
    }

    all_healthy = checks.values.all?
    status = all_healthy ? :ok : :service_unavailable
    render json: {
      status: all_healthy ? "ready" : "not_ready",
      checks: checks.transform_values { |v| v ? "ok" : "failing" }
    }, status: status
  end

  private

  def database_healthy?
    ActiveRecord::Base.connection.execute("SELECT 1")
    true
  rescue StandardError
    false
  end

  def migrations_current?
    ActiveRecord::Migration.check_all_pending!
    true
  rescue StandardError
    false
  end
end
```

Endpoints:

| Endpoint | Purpose |
|----------|---------|
| `GET /health/services` | Qdrant service health (degraded if unavailable) |
| `GET /health/liveness` | Always returns 200 if Rails process is alive |
| `GET /health/readiness` | Database connectivity + pending migrations check |
