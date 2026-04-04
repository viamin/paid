# Worker Pool Tuning Guide

This document covers optimal configuration for the two worker systems in Paid:
**GoodJob** (background jobs) and **Temporal** (workflow orchestration).

## GoodJob Configuration

GoodJob processes background jobs using a thread pool backed by PostgreSQL.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GOOD_JOB_EXECUTION_MODE` | `async_server` | `async_server` (in-process) or `external` (dedicated worker) |
| `GOOD_JOB_MAX_THREADS` | `10` | Worker thread pool size |
| `GOOD_JOB_QUEUES` | `default:3;maintenance:2;metrics:2;knowledge:2;low_priority:1` | Per-queue thread caps (semicolons create independent pools) |
| `GOOD_JOB_POLL_INTERVAL` | `3` | Seconds between DB polls for new jobs |
| `GOOD_JOB_SHUTDOWN_TIMEOUT` | `25` | Seconds to wait for in-flight jobs during shutdown |
| `GOOD_JOB_ENABLE_CRON` | `true` | Enable cron-scheduled jobs |

### Queue Priority Design

Jobs are assigned to five priority queues:

| Queue | Priority | Jobs | Rationale |
|---|---|---|---|
| `default` | 1 (highest) | ProcessRunQueue, DiagnoseError, HumanFeedback, GitHubTokenValidation, etc. | Core business logic that directly affects user-facing latency |
| `maintenance` | 2 | DockerOrphanCleanup, StaleRunDetector, WorktreeCleanup, PollWorkflowHealthCheck, etc. | Infrastructure health; important but tolerates brief delays |
| `metrics` | 3 | ContainerMetrics, ServiceContainerMetrics, QualityMetrics, AbTestAnalysis | Telemetry and analytics; deferrable under load without user impact |
| `knowledge` | 4 | EmbedChunks, StyleGuideExtraction, StyleGuideCompression | CPU-intensive embedding and LLM work; bursty, benefits from backpressure |
| `low_priority` | 5 (lowest) | DashboardBroadcast, LiveDashboardBroadcast, DelayedHumanFeedback | Non-urgent UI updates and batch processing |

### Thread Pool Sizing

The thread pool size (`GOOD_JOB_MAX_THREADS`) determines maximum job concurrency.
Each thread holds one database connection, so this value must not exceed `DB_POOL`.

The default configuration uses per-queue thread caps (semicolons in the queue string)
to create independent pools. That reserves capacity for critical queues so
bulk low-priority work cannot starve them:

| Queue | Threads | Purpose |
|---|---|---|
| `default` | 3 | Core business logic |
| `maintenance` | 2 | Cleanup and reconciliation |
| `metrics` | 2 | Telemetry collection |
| `knowledge` | 2 | Embedding (CPU-bound) |
| `low_priority` | 1 | Non-urgent batch work |

**Key constraint**: `DB_POOL >= RAILS_MAX_THREADS + GOOD_JOB_MAX_THREADS` when using
`async_server` mode (jobs run in the web process).

## Temporal Worker Configuration

The Temporal worker runs as a separate process (`bin/temporal_worker`) that executes
durable workflows and activities.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TEMPORAL_WORKFLOW_SLOTS` | `20` | Max concurrent workflow tasks |
| `TEMPORAL_ACTIVITY_SLOTS` | `4` | Max concurrent activity executions |
| `TEMPORAL_LOCAL_ACTIVITY_SLOTS` | `=ACTIVITY_SLOTS` | Max concurrent local activity executions |
| `TEMPORAL_MAX_CONCURRENT_ACTIVITY_TASK_POLLS` | `=ACTIVITY_SLOTS` | Concurrent activity task pollers |
| `TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASK_POLLS` | `=WORKFLOW_SLOTS` | Concurrent workflow task pollers |
| `TEMPORAL_GRACEFUL_SHUTDOWN_PERIOD` | `30` | Seconds for graceful shutdown |
| `TEMPORAL_FORCE_EXIT_BUFFER_SECONDS` | `10` | Extra seconds before forced exit |

### Activity Slots

Activity slots are the primary throughput bottleneck. Each activity slot represents
one concurrent agent execution (container launch, monitoring, teardown). Activities
are I/O-bound (waiting on Docker and LLM APIs), so more slots improve throughput
linearly up to the database connection limit.

**Key constraint**: `DB_POOL >= ACTIVITY_SLOTS + LOCAL_ACTIVITY_SLOTS + 2`
(the +2 accounts for heartbeat and polling threads).

### Workflow Slots

Workflow slots are lightweight (in-memory deterministic replay). The default of 20
is generous for most deployments. Only increase if you see workflow task backlog
growing in the Temporal UI.

## Deployment Sizing Recommendations

### Small (1-2 vCPU, 2-4 GB RAM, single server)

Suitable for solo developers or small teams with fewer than 10 concurrent agent runs.

```env
# Web server
WEB_CONCURRENCY=1
RAILS_MAX_THREADS=3

# GoodJob (in-process)
GOOD_JOB_EXECUTION_MODE=async_server
GOOD_JOB_MAX_THREADS=6
GOOD_JOB_QUEUES=default:2;maintenance:1;metrics:1;knowledge:1;low_priority:1
GOOD_JOB_POLL_INTERVAL=5

# Temporal worker
TEMPORAL_WORKFLOW_SLOTS=10
TEMPORAL_ACTIVITY_SLOTS=4
TEMPORAL_LOCAL_ACTIVITY_SLOTS=2

# Database
DB_POOL=20
```

### Medium (4 vCPU, 8 GB RAM, single or dual server)

Suitable for teams with 10-50 concurrent agent runs.

```env
# Web server
WEB_CONCURRENCY=2
RAILS_MAX_THREADS=5

# GoodJob (separate worker recommended)
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
GOOD_JOB_QUEUES=default:3;maintenance:2;metrics:2;knowledge:2;low_priority:1
GOOD_JOB_POLL_INTERVAL=3

# Temporal worker
TEMPORAL_WORKFLOW_SLOTS=20
TEMPORAL_ACTIVITY_SLOTS=8
TEMPORAL_LOCAL_ACTIVITY_SLOTS=4

# Database
DB_POOL=30
```

### Large (8+ vCPU, 16+ GB RAM, multi-server)

Suitable for organizations with 50+ concurrent agent runs. Run dedicated processes
for web, GoodJob, and Temporal workers.

```env
# Web server (per instance)
WEB_CONCURRENCY=auto
RAILS_MAX_THREADS=5

# GoodJob (dedicated worker process)
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=20
GOOD_JOB_QUEUES=default:6;maintenance:4;metrics:4;knowledge:4;low_priority:2
GOOD_JOB_POLL_INTERVAL=1

# Temporal worker (scale horizontally with multiple worker processes)
TEMPORAL_WORKFLOW_SLOTS=50
TEMPORAL_ACTIVITY_SLOTS=16
TEMPORAL_LOCAL_ACTIVITY_SLOTS=8

# Database (sized for web + GoodJob + Temporal combined)
DB_POOL=50
```

## Monitoring

### GoodJob

- **Dashboard**: Mount `GoodJob::Engine` at `/good_job` for a web UI showing queue depths, execution times, and error rates.
- **Key metrics**: Queue latency (time from enqueue to execution start), job error rate, thread pool utilization.
- **Alert on**: Queue latency exceeding 30s for `default` queue, error rate above 5%.

### Temporal

- **Dashboard**: Temporal UI at `TEMPORAL_UI_URL` (default `http://localhost:8080`).
- **Key metrics**: Workflow task backlog, activity task backlog, schedule-to-start latency.
- **Alert on**: Activity schedule-to-start latency exceeding 60s (indicates insufficient activity slots).

## Tuning Methodology

1. **Validate configuration first**: Run the worker pool validation specs (`spec/system/worker_pool_load_spec.rb`) to confirm the expected thread and slot limits are configured correctly.
2. **Identify the bottleneck**: Check if jobs are waiting in queue (increase threads) or if the database is saturated (reduce threads, add read replicas).
3. **Adjust incrementally**: Change one variable at a time and measure the impact on queue latency and throughput using runtime monitoring or a dedicated load test.
4. **Monitor connection usage**: `SELECT count(*) FROM pg_stat_activity` should stay well below `max_connections`.
