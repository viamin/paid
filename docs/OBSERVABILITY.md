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

### Metrics Definitions [IMPLEMENTED]

Metrics are defined in `Metrics::PrometheusCollector` and rendered in Prometheus text exposition format. The collector queries the database directly and caches results for 15 seconds.

#### Agent Run Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `paid_agent_runs_total` | gauge | Number of agent runs by status |
| `paid_agent_runs_active` | gauge | Currently active agent runs |
| `paid_agent_runs_queued` | gauge | Agent runs waiting in queue |

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

### Prometheus Configuration

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
      - targets: ['paid-web:3000']
    metrics_path: '/api/metrics'

  # Temporal server
  - job_name: 'temporal'
    static_configs:
      - targets: ['temporal:8000']

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

Paid uses Rails `ActiveSupport::TaggedLogging` with `config.log_tags = [:request_id]`. This prepends the request ID to each log line for correlation across a request lifecycle.

```ruby
# config/application.rb (or environment config)
config.log_tags = [:request_id]
```

### Correlation IDs

`Current.request_id` (provided by Rails) is used for correlation within a request. There is no custom `RequestIdMiddleware` — Rails sets `request_id` automatically via `ActionDispatch::RequestId`.

### Log Aggregation [PLANNED]

Logs are planned to be collected and shipped to Grafana Loki:

```yaml
# docker-compose.yml (logging section)
services:
  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"
    volumes:
      - loki-data:/loki

  promtail:
    image: grafana/promtail:latest
    volumes:
      - /var/log:/var/log:ro
      - ./promtail-config.yml:/etc/promtail/config.yml
    command: -config.file=/etc/promtail/config.yml
```

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

## Dashboards (Grafana) [PLANNED]

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

## Alerting [PLANNED]

### Alert Rules [PLANNED]

```yaml
# prometheus/rules/paid.yml
groups:
  - name: paid
    rules:
      # High error rate
      - alert: HighAgentFailureRate
        expr: |
          rate(paid_agent_runs_total{status="failed"}[1h])
          / rate(paid_agent_runs_total[1h]) > 0.3
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "High agent failure rate ({{ $value | humanizePercentage }})"

      # Budget exceeded
      - alert: ProjectBudgetExceeded
        expr: paid_cost_cents_total > paid_budget_limit_cents
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Project {{ $labels.project_id }} exceeded budget"

      # GitHub rate limit low
      - alert: GitHubRateLimitLow
        expr: paid_github_rate_limit_remaining < 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GitHub rate limit low ({{ $value }} remaining)"

      # Container startup slow
      - alert: SlowContainerStartup
        expr: |
          histogram_quantile(0.95, rate(paid_container_startup_seconds_bucket[1h])) > 30
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Container startup p95 is {{ $value }}s"

      # Disk space low
      - alert: DiskSpaceLow
        expr: paid_disk_usage_bytes{type="total"} / paid_disk_capacity_bytes > 0.85
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Disk usage above 85%"

      # Workflow queue backing up
      - alert: WorkflowQueueBacklog
        expr: temporal_workflow_task_schedule_to_start_latency_seconds > 60
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Temporal workflow queue backing up"

      # Quality degradation
      - alert: QualityDegradation
        expr: |
          avg_over_time(paid_quality_score[1h])
          < avg_over_time(paid_quality_score[7d]) * 0.8
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Quality score dropped significantly"
```

### Alert Routing [PLANNED]

```yaml
# alertmanager/alertmanager.yml
global:
  slack_api_url: '${SLACK_WEBHOOK_URL}'

route:
  receiver: 'default'
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - match:
        severity: critical
      receiver: 'critical'
      continue: true

receivers:
  - name: 'default'
    slack_configs:
      - channel: '#paid-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'

  - name: 'critical'
    slack_configs:
      - channel: '#paid-critical'
        title: 'CRITICAL: {{ .GroupLabels.alertname }}'
    # Optional: PagerDuty for critical alerts
    # pagerduty_configs:
    #   - service_key: '${PAGERDUTY_KEY}'
```

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

## Docker Compose (Observability Stack) [PLANNED]

```yaml
# docker-compose.observability.yml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/dashboards:/etc/grafana/provisioning/dashboards
      - ./grafana/datasources:/etc/grafana/provisioning/datasources

  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"
    volumes:
      - loki-data:/loki
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml

  promtail:
    image: grafana/promtail:latest
    volumes:
      - /var/log:/var/log:ro
      - ./promtail/promtail-config.yml:/etc/promtail/config.yml
    command: -config.file=/etc/promtail/config.yml

  alertmanager:
    image: prom/alertmanager:latest
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager:/etc/alertmanager

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    ports:
      - "8081:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    environment:
      - DATA_SOURCE_NAME=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/paid?sslmode=disable
    ports:
      - "9187:9187"

volumes:
  prometheus-data:
  grafana-data:
  loki-data:
```

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
