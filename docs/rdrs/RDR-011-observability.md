# RDR-011: Observability Stack

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Metrics endpoint tests, alert rule tests

## Problem Statement

Paid orchestrates AI agents, containers, and workflows. Operators need visibility into:

1. **System health**: Is Paid running correctly?
2. **Agent performance**: How are agents performing? What's the success rate?
3. **Cost tracking**: How much are we spending on LLM APIs?
4. **Workflow status**: Are workflows completing? Where are bottlenecks?
5. **Resource usage**: Container CPU/memory, database connections
6. **Alerting**: When should operators be notified?

Requirements:
- Real-time metrics for operations
- Historical data for trends
- Dashboards for visibility
- Alerting for critical issues
- Self-hosted solution preferred

## Context

### Background

Paid has multiple components that need monitoring:
- Rails application (web, API)
- Temporal server and workers
- PostgreSQL database
- Docker containers (agent execution)
- External API calls (GitHub, LLM providers)

The system should be observable from day one to catch issues before they become problems.

### Technical Environment

- Self-hosted deployment (Docker Compose)
- PostgreSQL database
- Temporal workflows
- Docker containers for agents

## Research Findings

### Investigation Process

1. Evaluated observability stacks (Prometheus/Grafana, DataDog, ELK)
2. Reviewed Rails instrumentation options
3. Analyzed Temporal observability features
4. Designed metric categories and alert rules
5. Reviewed container monitoring approaches

### Key Discoveries

**Prometheus + Grafana:**

Industry-standard, self-hosted observability stack:

- **Prometheus**: Time-series database for metrics, pull-based collection
- **Grafana**: Visualization and dashboards
- **AlertManager**: Alert routing and notification

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│ Rails App   │◄────────│ Prometheus  │────────►│ AlertManager│
│ /metrics    │  scrape │             │ alert   │             │
└─────────────┘         └──────┬──────┘         └─────────────┘
                               │
┌─────────────┐               │
│ Temporal    │◄──────────────┤
│ /metrics    │  scrape       │
└─────────────┘               │
                               │
┌─────────────┐               │
│ PostgreSQL  │◄──────────────┤
│ exporter    │  scrape       │
└─────────────┘               │
                               │
                               ▼
                        ┌─────────────┐
                        │  Grafana    │
                        │ dashboards  │
                        └─────────────┘
```

**Rails Metrics (prometheus-client gem):**

```ruby
# config/initializers/prometheus.rb
require 'prometheus/middleware/collector'
require 'prometheus/middleware/exporter'

Rails.application.middleware.use Prometheus::Middleware::Collector
Rails.application.middleware.use Prometheus::Middleware::Exporter

# Custom metrics
AGENT_RUNS_TOTAL = Prometheus::Client.registry.counter(
  :agent_runs_total,
  docstring: 'Total agent runs',
  labels: [:project, :agent_type, :status]
)

AGENT_RUN_DURATION = Prometheus::Client.registry.histogram(
  :agent_run_duration_seconds,
  docstring: 'Agent run duration',
  labels: [:project, :agent_type],
  buckets: [60, 300, 600, 1800, 3600]  # 1m, 5m, 10m, 30m, 1h
)

TOKEN_USAGE_TOTAL = Prometheus::Client.registry.counter(
  :token_usage_total,
  docstring: 'Total tokens used',
  labels: [:project, :provider, :type]  # type: input/output
)
```

**Temporal Metrics:**

Temporal server exposes Prometheus metrics at `/metrics`:

- `temporal_workflow_completed_total`
- `temporal_workflow_failed_total`
- `temporal_activity_execution_latency`
- `temporal_workflow_task_queue_depth`

**Key Metrics Categories:**

| Category | Metrics | Use |
|----------|---------|-----|
| Agent Runs | total, duration, success rate | Performance |
| Token Usage | by provider, model, project | Cost |
| Workflows | completed, failed, latency | Health |
| API Calls | latency, error rate | Dependencies |
| Resources | CPU, memory, connections | Capacity |
| Business | PRs created, merged rate | Outcomes |

**Alert Rules:**

Critical alerts:
- Agent success rate < 50% (15 min window)
- Workflow failure rate > 10%
- Token spend > daily budget
- Database connection exhaustion
- Container OOM kills

Warning alerts:
- Agent run duration > 30 min (p95)
- Workflow queue depth > 100
- API error rate > 5%
- Disk usage > 80%

## Proposed Solution

### Approach

Implement **Prometheus + Grafana** observability stack:

1. **Prometheus**: Collect metrics from all components
2. **Grafana**: Dashboards for visualization
3. **AlertManager**: Route alerts to appropriate channels
4. **Custom metrics**: Application-specific instrumentation
5. **Structured logging**: Complement metrics with logs

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      OBSERVABILITY ARCHITECTURE                              │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                      METRIC SOURCES                                      ││
│  │                                                                          ││
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐               ││
│  │  │ Rails App     │  │ Temporal      │  │ PostgreSQL    │               ││
│  │  │ :3000/metrics │  │ :7233/metrics │  │ exporter:9187 │               ││
│  │  │               │  │               │  │               │               ││
│  │  │ • HTTP reqs   │  │ • Workflows   │  │ • Connections │               ││
│  │  │ • Agent runs  │  │ • Activities  │  │ • Query perf  │               ││
│  │  │ • Token usage │  │ • Queue depth │  │ • Disk usage  │               ││
│  │  └───────────────┘  └───────────────┘  └───────────────┘               ││
│  │                                                                          ││
│  │  ┌───────────────┐  ┌───────────────┐                                   ││
│  │  │ Node Exporter │  │ cAdvisor      │                                   ││
│  │  │ :9100         │  │ :8080         │                                   ││
│  │  │               │  │               │                                   ││
│  │  │ • CPU/Memory  │  │ • Container   │                                   ││
│  │  │ • Disk I/O    │  │   resources   │                                   ││
│  │  │ • Network     │  │ • Agent usage │                                   ││
│  │  └───────────────┘  └───────────────┘                                   ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                      PROMETHEUS                                          ││
│  │                      :9090                                               ││
│  │                                                                          ││
│  │  • Scrapes all metric sources                                           ││
│  │  • Stores time-series data                                              ││
│  │  • Evaluates alert rules                                                ││
│  │  • Retention: 15 days (configurable)                                    ││
│  │                                                                          ││
│  └────────────────────────────────┬────────────────────────────────────────┘│
│                                   │                                          │
│              ┌────────────────────┼────────────────────┐                    │
│              ▼                    │                    ▼                    │
│  ┌───────────────────┐            │        ┌───────────────────┐            │
│  │ GRAFANA           │            │        │ ALERTMANAGER      │            │
│  │ :3000             │            │        │ :9093             │            │
│  │                   │            │        │                   │            │
│  │ • Dashboards      │            │        │ • Route alerts    │            │
│  │ • Visualizations  │            │        │ • Group/dedup     │            │
│  │ • Annotations     │            │        │ • Slack/email     │            │
│  └───────────────────┘            │        └───────────────────┘            │
│                                   │                                          │
│                                   │                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                      STRUCTURED LOGGING                                  ││
│  │                                                                          ││
│  │  Rails Logger → JSON format → Loki (optional) or stdout                 ││
│  │                                                                          ││
│  │  {                                                                       ││
│  │    "timestamp": "2025-01-23T10:30:00Z",                                 ││
│  │    "level": "info",                                                     ││
│  │    "message": "Agent run completed",                                    ││
│  │    "agent_run_id": 123,                                                 ││
│  │    "project_id": 45,                                                    ││
│  │    "duration_seconds": 342,                                             ││
│  │    "status": "success",                                                 ││
│  │    "trace_id": "abc123"                                                 ││
│  │  }                                                                       ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Self-hosted**: No external dependencies or costs
2. **Industry standard**: Prometheus/Grafana widely used, documented
3. **Extensible**: Easy to add new metrics and dashboards
4. **Temporal-native**: Temporal exports Prometheus metrics
5. **Alerting built-in**: AlertManager handles notifications

### Implementation Example

```ruby
# config/initializers/prometheus.rb
require 'prometheus/client'

# Register custom metrics
module Paid
  module Metrics
    # Agent metrics
    AGENT_RUNS = Prometheus::Client.registry.counter(
      :paid_agent_runs_total,
      docstring: 'Total agent runs',
      labels: [:project_id, :agent_type, :status]
    )

    AGENT_DURATION = Prometheus::Client.registry.histogram(
      :paid_agent_run_duration_seconds,
      docstring: 'Agent run duration in seconds',
      labels: [:project_id, :agent_type],
      buckets: [60, 120, 300, 600, 1200, 1800, 3600]
    )

    AGENT_ITERATIONS = Prometheus::Client.registry.histogram(
      :paid_agent_iterations,
      docstring: 'Number of iterations per agent run',
      labels: [:project_id, :agent_type],
      buckets: [1, 2, 3, 5, 10, 15, 20]
    )

    # Token metrics
    TOKEN_USAGE = Prometheus::Client.registry.counter(
      :paid_tokens_total,
      docstring: 'Total tokens used',
      labels: [:project_id, :provider, :model, :type]
    )

    COST_CENTS = Prometheus::Client.registry.counter(
      :paid_cost_cents_total,
      docstring: 'Total cost in cents',
      labels: [:project_id, :provider]
    )

    # Workflow metrics
    WORKFLOW_STARTED = Prometheus::Client.registry.counter(
      :paid_workflow_started_total,
      docstring: 'Workflows started',
      labels: [:workflow_type]
    )

    WORKFLOW_COMPLETED = Prometheus::Client.registry.counter(
      :paid_workflow_completed_total,
      docstring: 'Workflows completed',
      labels: [:workflow_type, :status]
    )

    # Quality metrics
    QUALITY_SCORE = Prometheus::Client.registry.histogram(
      :paid_quality_score,
      docstring: 'Quality scores for agent runs',
      labels: [:project_id, :prompt_slug],
      buckets: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    )
  end
end

# app/services/metrics_recorder.rb
class MetricsRecorder
  class << self
    def record_agent_run(agent_run)
      labels = {
        project_id: agent_run.project_id.to_s,
        agent_type: agent_run.agent_type,
        status: agent_run.status
      }

      Paid::Metrics::AGENT_RUNS.increment(labels: labels)

      if agent_run.completed?
        duration_labels = labels.except(:status)
        Paid::Metrics::AGENT_DURATION.observe(
          agent_run.duration_seconds,
          labels: duration_labels
        )
        Paid::Metrics::AGENT_ITERATIONS.observe(
          agent_run.iterations,
          labels: duration_labels
        )
      end
    end

    def record_token_usage(usage)
      labels = {
        project_id: usage.project_id.to_s,
        provider: usage.provider,
        model: usage.model_id,
        type: 'input'
      }

      Paid::Metrics::TOKEN_USAGE.increment(
        by: usage.tokens_input,
        labels: labels
      )

      Paid::Metrics::TOKEN_USAGE.increment(
        by: usage.tokens_output,
        labels: labels.merge(type: 'output')
      )

      Paid::Metrics::COST_CENTS.increment(
        by: usage.cost_cents,
        labels: labels.except(:type, :model)
      )
    end

    def record_quality_score(quality_metric)
      Paid::Metrics::QUALITY_SCORE.observe(
        quality_metric.quality_score,
        labels: {
          project_id: quality_metric.agent_run.project_id.to_s,
          prompt_slug: quality_metric.prompt_version.prompt.slug
        }
      )
    end
  end
end

# config/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'rails'
    static_configs:
      - targets: ['rails:3000']
    metrics_path: /metrics

  - job_name: 'temporal'
    static_configs:
      - targets: ['temporal:7233']
    metrics_path: /metrics

  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres-exporter:9187']

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
```

```yaml
# prometheus/rules/paid.yml
groups:
  - name: paid_alerts
    rules:
      - alert: AgentSuccessRateLow
        expr: |
          (
            sum(rate(paid_agent_runs_total{status="completed"}[15m]))
            /
            sum(rate(paid_agent_runs_total[15m]))
          ) < 0.5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Agent success rate below 50%"
          description: "Agent success rate is {{ $value | humanizePercentage }}"

      - alert: DailyBudgetExceeded
        expr: |
          sum by (project_id) (
            increase(paid_cost_cents_total[24h])
          ) > 10000  # $100
        labels:
          severity: warning
        annotations:
          summary: "Daily budget exceeded for project {{ $labels.project_id }}"

      - alert: WorkflowQueueDepth
        expr: temporal_workflow_task_queue_depth > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Workflow queue depth high"

      - alert: AgentRunDurationHigh
        expr: |
          histogram_quantile(0.95, rate(paid_agent_run_duration_seconds_bucket[1h])) > 1800
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "95th percentile agent run duration over 30 minutes"
```

## Alternatives Considered

### Alternative 1: DataDog

**Description**: Use DataDog for observability

**Pros**:
- All-in-one solution
- Excellent UI
- APM built-in
- Managed service

**Cons**:
- Expensive at scale
- External dependency
- Data leaves infrastructure

**Reason for rejection**: Cost and self-hosted preference. Prometheus/Grafana provides similar capabilities without ongoing costs.

### Alternative 2: ELK Stack

**Description**: Elasticsearch, Logstash, Kibana for logs and metrics

**Pros**:
- Powerful log analysis
- Good search capabilities
- Single stack

**Cons**:
- Resource-heavy (Elasticsearch)
- Complex to operate
- Logs focus (metrics less native)

**Reason for rejection**: Prometheus is better for metrics. Could add Loki for logs separately.

### Alternative 3: No Monitoring (Rails Logs Only)

**Description**: Rely on application logs for observability

**Pros**:
- Simplest approach
- No additional infrastructure

**Cons**:
- No visualization
- Hard to spot trends
- No alerting
- Difficult to correlate

**Reason for rejection**: Insufficient for production operations. Need proactive alerting and dashboards.

### Alternative 4: Cloud Provider Monitoring

**Description**: Use AWS CloudWatch, GCP Monitoring, etc.

**Pros**:
- Integrated with infrastructure
- Managed service
- Auto-discovery

**Cons**:
- Cloud lock-in
- May not support self-hosted deployment
- Cost at scale

**Reason for rejection**: Paid should be self-hostable without cloud dependencies.

## Trade-offs and Consequences

### Positive Consequences

- **Full visibility**: Dashboards show system health at a glance
- **Proactive alerting**: Issues caught before users notice
- **Cost tracking**: Token spend visible in real-time
- **Performance insights**: Identify slow agents and bottlenecks
- **Self-hosted**: No external dependencies or costs

### Negative Consequences

- **Operational overhead**: Another stack to maintain
- **Storage**: Prometheus needs disk for time-series data
- **Learning curve**: Prometheus query language (PromQL)

### Risks and Mitigations

- **Risk**: Prometheus storage fills up
  **Mitigation**: Configure retention appropriately. Monitor disk usage. Archive old data.

- **Risk**: Alert fatigue
  **Mitigation**: Tune thresholds carefully. Use inhibition rules. Start conservative.

- **Risk**: Grafana becomes single point of access
  **Mitigation**: Prometheus is the data source; can access directly if Grafana is down.

## Implementation Plan

### Prerequisites

- [ ] Docker Compose environment set up
- [ ] prometheus-client gem added
- [ ] Rails metrics endpoint exposed

### Step-by-Step Implementation

#### Step 1: Add Gems

```ruby
# Gemfile
gem "prometheus-client"
```

#### Step 2: Configure Prometheus Client

Create `config/initializers/prometheus.rb` as shown above.

#### Step 3: Add Metrics Middleware

```ruby
# config/application.rb
config.middleware.use Prometheus::Middleware::Exporter
```

#### Step 4: Docker Compose Services

```yaml
# docker-compose.yml
services:
  prometheus:
    image: prom/prometheus:v2.47.0
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:10.2.0
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
    ports:
      - "3001:3000"

  alertmanager:
    image: prom/alertmanager:v0.26.0
    volumes:
      - ./alertmanager:/etc/alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
    ports:
      - "9093:9093"

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.15.0
    environment:
      - DATA_SOURCE_NAME=postgresql://paid:${POSTGRES_PASSWORD}@postgres:5432/paid_production?sslmode=disable
    ports:
      - "9187:9187"

  node-exporter:
    image: prom/node-exporter:v1.7.0
    ports:
      - "9100:9100"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.0
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports:
      - "8080:8080"

volumes:
  prometheus_data:
  grafana_data:
```

#### Step 5: Create Grafana Dashboards

Create JSON dashboard definitions in `grafana/provisioning/dashboards/`.

### Files to Create/Modify

- `Gemfile` - Add prometheus-client
- `config/initializers/prometheus.rb`
- `app/services/metrics_recorder.rb`
- `docker-compose.yml` - Add monitoring services
- `prometheus/prometheus.yml`
- `prometheus/rules/paid.yml`
- `alertmanager/alertmanager.yml`
- `grafana/provisioning/` - Dashboards and datasources

### Dependencies

- `prometheus-client` gem (~> 4.0)
- Prometheus server
- Grafana
- AlertManager
- postgres_exporter
- node_exporter
- cAdvisor

## Validation

### Testing Approach

1. Metrics endpoint returns expected format
2. Alert rules fire correctly on test data
3. Dashboards display expected metrics
4. Notifications reach configured channels

### Test Scenarios

1. **Scenario**: Agent run completes
   **Expected Result**: Metrics updated, visible in Grafana

2. **Scenario**: Success rate drops below 50%
   **Expected Result**: Alert fires within 5 minutes

3. **Scenario**: Daily budget exceeded
   **Expected Result**: Warning alert sent

4. **Scenario**: Prometheus restarts
   **Expected Result**: Metrics continue from last checkpoint

### Performance Validation

- Metrics endpoint responds in < 50ms
- Prometheus scrape completes in < 5 seconds
- Dashboard queries return in < 2 seconds

### Security Validation

- Prometheus not exposed to public internet
- Grafana requires authentication
- Sensitive metrics not exposed to unauthorized users

## References

### Requirements & Standards

- Paid OBSERVABILITY.md - Detailed observability design
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)

### Dependencies

- [prometheus-client Ruby](https://github.com/prometheus/client_ruby)
- [Prometheus](https://prometheus.io/)
- [Grafana](https://grafana.com/)
- [AlertManager](https://prometheus.io/docs/alerting/alertmanager/)

### Research Resources

- Prometheus instrumentation patterns
- Grafana dashboard examples
- SRE observability practices

## Notes

- Start with key metrics; add more as needed
- Tune alert thresholds based on observed patterns
- Consider Loki for log aggregation later
- Dashboard templates can be shared via Grafana JSON export
