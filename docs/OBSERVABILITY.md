# Paid Observability

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

## Metrics (Prometheus)

### Stack

| Component | Purpose |
|-----------|---------|
| Prometheus | Time-series metrics storage and alerting |
| Grafana | Visualization and dashboards |
| prometheus-client (gem) | Ruby metrics exposition |
| Temporal metrics | Workflow and activity metrics |

### Metrics Categories

#### Application Metrics

```ruby
# config/initializers/prometheus.rb
require 'prometheus/client'

PROMETHEUS = Prometheus::Client.registry

# Counters
AGENT_RUNS_TOTAL = PROMETHEUS.counter(
  :paid_agent_runs_total,
  docstring: 'Total agent runs',
  labels: [:project_id, :agent_type, :status]
)

TOKENS_USED_TOTAL = PROMETHEUS.counter(
  :paid_tokens_used_total,
  docstring: 'Total tokens consumed',
  labels: [:project_id, :model, :direction]  # direction: input/output
)

PR_CREATED_TOTAL = PROMETHEUS.counter(
  :paid_prs_created_total,
  docstring: 'Total PRs created by agents',
  labels: [:project_id]
)

# Gauges
ACTIVE_WORKFLOWS = PROMETHEUS.gauge(
  :paid_active_workflows,
  docstring: 'Currently running workflows',
  labels: [:workflow_type]
)

ACTIVE_CONTAINERS = PROMETHEUS.gauge(
  :paid_active_containers,
  docstring: 'Currently running agent containers',
  labels: [:project_id]
)

WORKTREE_COUNT = PROMETHEUS.gauge(
  :paid_worktrees_total,
  docstring: 'Active git worktrees',
  labels: [:project_id]
)

# Histograms
AGENT_RUN_DURATION = PROMETHEUS.histogram(
  :paid_agent_run_duration_seconds,
  docstring: 'Agent run duration',
  labels: [:project_id, :agent_type],
  buckets: [30, 60, 120, 300, 600, 1200, 1800, 3600]
)

CONTAINER_STARTUP_DURATION = PROMETHEUS.histogram(
  :paid_container_startup_seconds,
  docstring: 'Container startup time',
  buckets: [1, 2, 5, 10, 20, 30, 60]
)

LLM_REQUEST_DURATION = PROMETHEUS.histogram(
  :paid_llm_request_seconds,
  docstring: 'LLM API request duration',
  labels: [:provider, :model],
  buckets: [0.5, 1, 2, 5, 10, 30, 60, 120]
)
```

#### Business Metrics

```ruby
# Cost tracking
COST_CENTS = PROMETHEUS.counter(
  :paid_cost_cents_total,
  docstring: 'Total cost in cents',
  labels: [:project_id, :model]
)

# Quality metrics
QUALITY_SCORE = PROMETHEUS.histogram(
  :paid_quality_score,
  docstring: 'Agent run quality scores',
  labels: [:project_id, :prompt_slug],
  buckets: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
)

ITERATIONS_TO_COMPLETE = PROMETHEUS.histogram(
  :paid_iterations_to_complete,
  docstring: 'Iterations needed to complete task',
  labels: [:project_id, :agent_type],
  buckets: [1, 2, 3, 4, 5, 7, 10, 15, 20]
)

PR_MERGE_RATE = PROMETHEUS.gauge(
  :paid_pr_merge_rate,
  docstring: 'PR merge rate (rolling 7 days)',
  labels: [:project_id]
)
```

#### Infrastructure Metrics

```ruby
# GitHub API
GITHUB_API_CALLS = PROMETHEUS.counter(
  :paid_github_api_calls_total,
  docstring: 'GitHub API calls',
  labels: [:endpoint, :status]
)

GITHUB_RATE_LIMIT_REMAINING = PROMETHEUS.gauge(
  :paid_github_rate_limit_remaining,
  docstring: 'GitHub API rate limit remaining',
  labels: [:token_id]
)

# Disk usage
DISK_USAGE_BYTES = PROMETHEUS.gauge(
  :paid_disk_usage_bytes,
  docstring: 'Disk usage',
  labels: [:type]  # repos, worktrees, logs, containers
)
```

### Metrics Exposition

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Prometheus scrape endpoint
  get '/metrics', to: 'metrics#index'
end

# app/controllers/metrics_controller.rb
class MetricsController < ApplicationController
  skip_before_action :authenticate_user!

  def index
    # Optional: restrict to internal network
    unless request.local? || internal_network?
      head :forbidden
      return
    end

    render plain: Prometheus::Client::Formats::Text.marshal(PROMETHEUS),
           content_type: 'text/plain; version=0.0.4'
  end

  private

  def internal_network?
    # Check if request comes from Prometheus server
    request.ip.start_with?('10.', '172.16.', '192.168.')
  end
end
```

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
    metrics_path: '/metrics'

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

## Structured Logging

### Log Format

All logs use structured JSON format for easy parsing:

```ruby
# config/initializers/logging.rb
Rails.application.configure do
  config.log_formatter = proc do |severity, timestamp, progname, msg|
    log_entry = {
      timestamp: timestamp.iso8601(3),
      level: severity,
      message: msg.is_a?(Hash) ? msg[:message] : msg,
      **extract_metadata(msg)
    }
    "#{log_entry.to_json}\n"
  end
end
```

### Log Schema

```json
{
  "timestamp": "2024-01-15T10:30:00.123Z",
  "level": "INFO",
  "message": "agent_execution.completed",
  "trace_id": "abc123",
  "span_id": "def456",
  "context": {
    "agent_run_id": 42,
    "project_id": 7,
    "workflow_id": "execution-42-xyz"
  },
  "metrics": {
    "duration_ms": 45000,
    "iterations": 3,
    "tokens_used": 15000
  }
}
```

### Correlation IDs

Every request and workflow gets a trace ID for correlation:

```ruby
# app/middleware/request_id_middleware.rb
class RequestIdMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    trace_id = env['HTTP_X_REQUEST_ID'] || SecureRandom.uuid
    Current.trace_id = trace_id

    status, headers, response = @app.call(env)

    headers['X-Request-ID'] = trace_id
    [status, headers, response]
  end
end

# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :trace_id, :user, :account
end
```

### Log Aggregation

Logs are collected and shipped to Grafana Loki:

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

### Custom Workflow Metrics

```ruby
# app/workflows/concerns/observable.rb
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

## Dashboards (Grafana)

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

## Alerting

### Alert Rules

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

### Alert Routing

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

## Resource Cleanup

### Worktree Cleanup Strategy

Worktrees consume disk space and must be cleaned up after use:

```ruby
# app/services/worktree_cleanup_service.rb
class WorktreeCleanupService
  # Cleanup triggers:
  # 1. Immediately after PR created (success path)
  # 2. Immediately after agent failure (failure path)
  # 3. Periodically for orphaned worktrees (background job)

  ORPHAN_THRESHOLD = 24.hours

  def cleanup_for_agent_run(agent_run)
    return unless agent_run.worktree_path.present?

    container = agent_run.container
    worktree_path = agent_run.worktree_path
    branch_name = agent_run.branch_name

    # Remove worktree
    container.exec([
      "git", "-C", repo_path(agent_run.project),
      "worktree", "remove", "--force", worktree_path
    ])

    # Delete branch if PR not created
    unless agent_run.pull_request_url.present?
      container.exec([
        "git", "-C", repo_path(agent_run.project),
        "branch", "-D", branch_name
      ])
    end

    # Update metrics
    WORKTREE_COUNT.decrement(labels: { project_id: agent_run.project_id })

    Rails.logger.info(
      message: "worktree.cleaned",
      agent_run_id: agent_run.id,
      worktree_path: worktree_path
    )
  end

  def cleanup_orphaned_worktrees
    Project.active.find_each do |project|
      cleanup_orphaned_for_project(project)
    end
  end

  private

  def cleanup_orphaned_for_project(project)
    container = ContainerService.new.get_or_provision(project)
    repo_path = repo_path(project)

    # List all worktrees
    result = container.exec(["git", "-C", repo_path, "worktree", "list", "--porcelain"])
    worktrees = parse_worktree_list(result.output)

    # Find active agent runs
    active_worktrees = AgentRun
      .where(project: project, status: [:pending, :running])
      .pluck(:worktree_path)
      .compact

    # Identify orphans (worktrees without active runs)
    orphans = worktrees.reject { |w| active_worktrees.include?(w[:path]) }

    orphans.each do |worktree|
      # Check age
      next if worktree[:created_at] > ORPHAN_THRESHOLD.ago

      Rails.logger.warn(
        message: "worktree.orphan_detected",
        project_id: project.id,
        worktree_path: worktree[:path],
        age_hours: ((Time.current - worktree[:created_at]) / 1.hour).round
      )

      # Clean up
      container.exec(["git", "-C", repo_path, "worktree", "remove", "--force", worktree[:path]])
      WORKTREE_COUNT.decrement(labels: { project_id: project.id })
    end
  end
end
```

### Container Cleanup

```ruby
# app/services/container_cleanup_service.rb
class ContainerCleanupService
  IDLE_THRESHOLD = 30.minutes
  MAX_CONTAINER_AGE = 24.hours

  def cleanup_idle_containers
    Container.where(status: :idle)
      .where("last_used_at < ?", IDLE_THRESHOLD.ago)
      .find_each do |container|
        stop_and_remove(container)
      end
  end

  def cleanup_old_containers
    Container.where("created_at < ?", MAX_CONTAINER_AGE.ago)
      .find_each do |container|
        stop_and_remove(container)
      end
  end

  def cleanup_orphaned_containers
    # Find Docker containers not tracked in database
    docker_containers = docker_client.containers.all(
      filters: { label: ["paid.managed=true"] }
    )

    tracked_ids = Container.pluck(:docker_id)

    docker_containers.each do |dc|
      next if tracked_ids.include?(dc.id)

      Rails.logger.warn(
        message: "container.orphan_detected",
        docker_id: dc.id,
        name: dc.info["Names"].first
      )

      dc.stop
      dc.remove
    end
  end

  private

  def stop_and_remove(container)
    docker_container = docker_client.containers.get(container.docker_id)
    docker_container.stop(timeout: 10)
    docker_container.remove

    ACTIVE_CONTAINERS.decrement(labels: { project_id: container.project_id })

    container.destroy

    Rails.logger.info(
      message: "container.removed",
      container_id: container.id,
      docker_id: container.docker_id
    )
  rescue Docker::Error::NotFoundError
    # Container already gone
    container.destroy
  end
end
```

### Disk Space Monitoring

```ruby
# app/jobs/disk_cleanup_job.rb
class DiskCleanupJob < ApplicationJob
  queue_as :maintenance

  THRESHOLDS = {
    warning: 0.75,
    critical: 0.85,
    emergency: 0.95
  }.freeze

  def perform
    usage = calculate_disk_usage

    # Update metrics
    usage.each do |type, bytes|
      DISK_USAGE_BYTES.set(bytes, labels: { type: type })
    end

    utilization = usage[:total].to_f / disk_capacity

    case utilization
    when THRESHOLDS[:emergency]..1.0
      emergency_cleanup!
    when THRESHOLDS[:critical]...THRESHOLDS[:emergency]
      aggressive_cleanup!
    when THRESHOLDS[:warning]...THRESHOLDS[:critical]
      routine_cleanup!
    end
  end

  private

  def routine_cleanup!
    Rails.logger.info(message: "disk_cleanup.routine")
    WorktreeCleanupService.new.cleanup_orphaned_worktrees
    ContainerCleanupService.new.cleanup_idle_containers
    cleanup_old_logs(older_than: 30.days)
  end

  def aggressive_cleanup!
    Rails.logger.warn(message: "disk_cleanup.aggressive")
    routine_cleanup!
    ContainerCleanupService.new.cleanup_old_containers
    cleanup_old_logs(older_than: 7.days)
    prune_docker_images!
  end

  def emergency_cleanup!
    Rails.logger.error(message: "disk_cleanup.emergency")
    aggressive_cleanup!
    cleanup_old_logs(older_than: 1.day)
    # Stop accepting new agent runs until space is freed
    Rails.cache.write("disk_emergency", true, expires_in: 1.hour)
  end

  def cleanup_old_logs(older_than:)
    AgentRunLog.where("created_at < ?", older_than.ago).delete_all
  end

  def prune_docker_images!
    docker_client.images.prune(filters: { dangling: ["true"] })
  end
end
```

### Scheduled Cleanup Jobs

```yaml
# config/recurring.yml
disk_cleanup:
  class: DiskCleanupJob
  schedule: every 1 hour

worktree_cleanup:
  class: WorktreeOrphanCleanupJob
  schedule: every 6 hours

container_cleanup:
  class: ContainerCleanupJob
  schedule: every 30 minutes

log_retention:
  class: LogRetentionJob
  schedule: every day at 3am
```

---

## Docker Compose (Observability Stack)

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

## Health Checks

```ruby
# app/controllers/health_controller.rb
class HealthController < ApplicationController
  skip_before_action :authenticate_user!

  # GET /health - Basic liveness
  def show
    head :ok
  end

  # GET /health/ready - Readiness (dependencies)
  def ready
    checks = {
      database: check_database,
      temporal: check_temporal,
      redis: check_redis,
      docker: check_docker
    }

    if checks.values.all?
      render json: { status: 'ok', checks: checks }
    else
      render json: { status: 'degraded', checks: checks }, status: :service_unavailable
    end
  end

  private

  def check_database
    ActiveRecord::Base.connection.execute('SELECT 1')
    true
  rescue
    false
  end

  def check_temporal
    Paid::TemporalClient.instance.connection.get_system_info
    true
  rescue
    false
  end

  def check_redis
    Rails.cache.redis.ping == 'PONG'
  rescue
    false
  end

  def check_docker
    Docker.ping == 'OK'
  rescue
    false
  end
end
```
