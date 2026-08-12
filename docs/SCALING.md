# Scaling Guide

This document covers the scaling architecture, configuration, capacity planning, and
operational procedures for running Paid in production at various scales.

For worker-specific tuning details, see [WORKER_POOL_TUNING.md](WORKER_POOL_TUNING.md).
For monitoring and alerting, see [OBSERVABILITY.md](OBSERVABILITY.md).

## Orchestrator Integrations

Paid's scaling decision layer is infrastructure-agnostic. `Scaling::Orchestrator`
adapters translate those decisions into platform-specific actions:

| Adapter | Primary target | Notes |
|---------|----------------|-------|
| `Scaling::Orchestrators::KubernetesAdapter` | Kubernetes Deployments | Direct replica scaling plus resource-limit patching |
| `Scaling::Orchestrators::DockerSwarmAdapter` | Docker Swarm services | Uses `docker service` CLI commands against a Swarm manager |
| `Scaling::Orchestrators::EcsAdapter` | Amazon ECS services | Uses the AWS CLI to scale services and roll task-definition revisions |
| `Scaling::Orchestrators::DockerComposeAdapter` | Local/dev Docker Compose | Development and CI fallback, not a production auto-scaling target |

## Architecture Overview

Paid has four independently scalable process types:

```
                        ┌─────────────────┐
                        │  Load Balancer  │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
     ┌────────────────┐ ┌────────────────┐  ┌────────────────┐
     │   Web (Puma)   │ │   Web (Puma)   │  │   Web (Puma)   │
     │  N workers ×   │ │  N workers ×   │  │  N workers ×   │
     │  M threads     │ │  M threads     │  │  M threads     │
     └────────┬───────┘ └────────┬───────┘  └────────┬───────┘
              │                  │                    │
              └──────────────────┼────────────────────┘
                                 │
                                 ▼
                        ┌────────────────┐
                        │   PostgreSQL   │
                        │  (all state)   │
                        └────────┬───────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                   │
     ┌────────────────┐ ┌────────────────┐  ┌────────────────┐
     │ GoodJob Worker │ │Temporal Worker │  │ Docker Engine  │
     │  (background   │ │  (durable      │  │  (agent        │
     │   jobs)        │ │   workflows)   │  │   containers)  │
     └────────────────┘ └────────────────┘  └────────────────┘
```

### Process Types

| Process | Purpose | Scaling Dimension | Bottleneck |
|---------|---------|-------------------|------------|
| **Web (Puma)** | HTTP requests, UI, Action Cable | Horizontal (add instances) | CPU-bound request handling |
| **GoodJob Worker** | Background jobs (cleanup, metrics, cron) | Thread pool size | DB connections |
| **Temporal Worker** | Durable workflow orchestration | Activity slots | DB connections, Docker capacity |
| **Docker Engine** | Agent container execution | Host memory and CPU | 4 GB RAM per container default |

### Kamal Roles (`config/deploy.yml`)

Production maps the process types above to four Kamal roles, each deployed as a
separate Docker container with its own restart boundary:

| Role | CMD | Key env vars | Purpose |
|------|-----|--------------|---------|
| `web` | `bin/thrust bin/rails server` (Dockerfile CMD) | `GOOD_JOB_EXECUTION_MODE=external`, Puma vars | HTTP/UI; runs no jobs in-process |
| `job` | `bin/jobs` | `GOOD_JOB_*` (threads, queues) | External GoodJob worker |
| `worker_poll` | `bin/temporal_worker` | `TEMPORAL_WORKER_MODE=poll` | Poll-queue Temporal worker |
| `worker_agent` | `bin/temporal_worker` | `TEMPORAL_WORKER_MODE=agent` | Agent-queue Temporal worker |

`GOOD_JOB_EXECUTION_MODE=external` is set globally so the `web` role never runs
background jobs (preventing job load from OOM-crashing the control plane). Target
a single role with `bin/kamal <cmd> -r <role>` (e.g. `bin/kamal app boot -r job`).
For env-var sizing per role, see [WORKER_POOL_TUNING.md](WORKER_POOL_TUNING.md).

### Scaling Decision Flow

```
Is the web UI slow or timing out?
  ├─ Yes → Scale web: increase WEB_CONCURRENCY or add web instances
  └─ No
      │
      ▼
Are background jobs delayed (queue latency > 30s)?
  ├─ Yes → Scale GoodJob: increase GOOD_JOB_MAX_THREADS or run external worker
  └─ No
      │
      ▼
Are agent runs waiting to start (schedule-to-start latency > 60s)?
  ├─ Yes → Scale Temporal: increase TEMPORAL_ACTIVITY_SLOTS
  │         └─ Still waiting? → Add Docker host capacity (RAM/CPU)
  └─ No
      │
      ▼
Is the database connection pool exhausted?
  ├─ Yes → Increase DB_POOL, or increase PostgreSQL max_connections
  └─ No → System is healthy at current scale
```

## Configuration Reference

### Web Server (Puma)

| Variable | Default | Description |
|----------|---------|-------------|
| `WEB_CONCURRENCY` | `1` | Puma worker processes (set `auto` for one per CPU) |
| `RAILS_MAX_THREADS` | `3` | Threads per Puma worker |
| `PORT` | `3000` | HTTP listen port |

Each Puma worker is a forked process with its own thread pool and DB connection pool.
Total web threads = `WEB_CONCURRENCY × RAILS_MAX_THREADS`.

### Background Jobs (GoodJob)

| Variable | Default | Description |
|----------|---------|-------------|
| `GOOD_JOB_EXECUTION_MODE` | `async_server` | `async_server` (in-process) or `external` (dedicated worker) |
| `GOOD_JOB_MAX_THREADS` | `11` | Total job worker threads |
| `GOOD_JOB_QUEUES` | `default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1` | Per-queue thread caps |
| `GOOD_JOB_POLL_INTERVAL` | `3` | Seconds between DB polls |
| `GOOD_JOB_SHUTDOWN_TIMEOUT` | `25` | Graceful shutdown timeout (seconds) |
| `GOOD_JOB_ENABLE_CRON` | `true` | Enable cron-scheduled jobs |

**Execution modes:**

- `async_server` — jobs run inside the web process. Simpler to deploy but shares
  DB connections with Puma. Best for small deployments.
- `external` — jobs run in a dedicated `bin/jobs` process. Required for medium+ deployments
  so job work does not compete with request handling.

### Workflow Orchestration (Temporal)

| Variable | Default | Description |
|----------|---------|-------------|
| `TEMPORAL_ADDRESS` | `localhost:7233` | Temporal server address |
| `TEMPORAL_NAMESPACE` | `default` | Temporal namespace |
| `TEMPORAL_WORKER_MODE` | `both` | Which worker set a `bin/temporal_worker` process boots |
| `TEMPORAL_POLL_TASK_QUEUE` | `paid-poll-tasks` | Poll workflow task queue |
| `TEMPORAL_AGENT_TASK_QUEUE` | `paid-agent-tasks` | Agent execution task queue |
| `TEMPORAL_WORKFLOW_SLOTS` | `20` | Max concurrent workflow tasks |
| `TEMPORAL_ACTIVITY_SLOTS` | `4` | Max concurrent activity executions (agent worker) |
| `TEMPORAL_LOCAL_ACTIVITY_SLOTS` | `=TEMPORAL_ACTIVITY_SLOTS` | Max concurrent local activities (agent worker) |
| `TEMPORAL_POLL_ACTIVITY_SLOTS` | `4` | Max concurrent activity executions (poll worker) |
| `TEMPORAL_POLL_LOCAL_ACTIVITY_SLOTS` | `=TEMPORAL_POLL_ACTIVITY_SLOTS` | Max concurrent local activities (poll worker) |
| `TEMPORAL_MAX_CONCURRENT_ACTIVITY_TASK_POLLS` | `=TEMPORAL_ACTIVITY_SLOTS` | Activity task pollers |
| `TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASK_POLLS` | `=TEMPORAL_WORKFLOW_SLOTS` | Workflow task pollers |
| `TEMPORAL_GRACEFUL_SHUTDOWN_PERIOD` | `30` | Graceful shutdown (seconds) |
| `TEMPORAL_FORCE_EXIT_BUFFER_SECONDS` | `10` | Extra seconds before forced exit |

**Activity slots** are the primary throughput control for agent execution. Each slot
represents one concurrent container (launch, monitor, teardown). Activities are I/O-bound,
so more slots improve throughput linearly up to the DB connection and Docker host limits.

### Database

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | PostgreSQL connection string |
| `DB_POOL` | `20` | Connection pool size per process |
| `DB_HOST` | — | Database hostname (alternative to DATABASE_URL) |

**Pool sizing constraints:**

- `async_server` mode: `DB_POOL >= RAILS_MAX_THREADS + GOOD_JOB_MAX_THREADS`
- Temporal worker in `agent` mode: `DB_POOL >= TEMPORAL_ACTIVITY_SLOTS + TEMPORAL_LOCAL_ACTIVITY_SLOTS + TEMPORAL_ACTIVITY_SLOTS + 2`
- Temporal worker in `poll` mode: `DB_POOL >= TEMPORAL_POLL_ACTIVITY_SLOTS + TEMPORAL_POLL_LOCAL_ACTIVITY_SLOTS + 2`
- Temporal worker in `both` mode: `DB_POOL >= (TEMPORAL_ACTIVITY_SLOTS + TEMPORAL_LOCAL_ACTIVITY_SLOTS + TEMPORAL_POLL_ACTIVITY_SLOTS + TEMPORAL_POLL_LOCAL_ACTIVITY_SLOTS) + TEMPORAL_ACTIVITY_SLOTS + 4`
- Each agent activity holds **two** connections (its main thread + a heartbeat worker thread that streams output to the DB), so `TEMPORAL_ACTIVITY_SLOTS` is counted twice. `bin/temporal_worker` auto-corrects the pool at boot if `DB_POOL` is below the minimum.
- Total connections across all processes must not exceed PostgreSQL `max_connections`

### Agent Containers

| Setting | Default | Description |
|---------|---------|-------------|
| Memory limit | 4 GB | Per-container memory (overridable per user) |
| CPU quota | 200,000 (2 CPUs) | CPU cycles per period |
| PID limit | 500 | Max processes per container |
| Execution timeout | 3,600s (1 hour) | Max run duration |
| `/tmp` tmpfs | 1 GB | Temporary filesystem |
| Cache tmpfs | 512 MB | Package cache filesystem |

## Deployment Tiers

### Small — Solo/Small Team

**Profile:** 1-2 vCPU, 2-4 GB RAM, single server, < 10 concurrent agent runs.

All processes run on one host. GoodJob runs in-process with the web server.

```
┌─────────────────────────────────────────┐
│              Single Host                │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  Puma (web + GoodJob in-proc)  │    │
│  └─────────────────────────────────┘    │
│  ┌─────────────────────────────────┐    │
│  │  Temporal Worker                │    │
│  └─────────────────────────────────┘    │
│  ┌─────────────────────────────────┐    │
│  │  PostgreSQL                     │    │
│  └─────────────────────────────────┘    │
│  ┌─────────────────────────────────┐    │
│  │  Temporal Server                │    │
│  └─────────────────────────────────┘    │
│  ┌────────┐ ┌────────┐ ┌────────┐      │
│  │Agent C.│ │Agent C.│ │Agent C.│      │
│  └────────┘ └────────┘ └────────┘      │
└─────────────────────────────────────────┘
```

```env
WEB_CONCURRENCY=1
RAILS_MAX_THREADS=3
GOOD_JOB_EXECUTION_MODE=async_server
GOOD_JOB_MAX_THREADS=6
GOOD_JOB_QUEUES=default:2;maintenance:1;metrics:1;knowledge:1;low_priority:1
GOOD_JOB_POLL_INTERVAL=5
TEMPORAL_WORKFLOW_SLOTS=10
TEMPORAL_ACTIVITY_SLOTS=4
TEMPORAL_LOCAL_ACTIVITY_SLOTS=2
DB_POOL=20
```

**Resource budget:**

- PostgreSQL: ~200 MB RAM
- Temporal Server: ~300 MB RAM
- Puma + GoodJob: ~400 MB RAM
- Per agent container: 4 GB RAM
- Max concurrent containers at 4 GB each: **3-4** (with 16 GB host) or **1** (with 4 GB host)

### Medium — Team

**Profile:** 4 vCPU, 8 GB RAM, single or dual server, 10-50 concurrent agent runs.

GoodJob runs as a separate process. Consider splitting the database to its own host.

```
┌──────────────────────┐  ┌──────────────────────┐
│      App Host        │  │    Docker Host(s)    │
│                      │  │                      │
│  ┌────────────────┐  │  │  ┌────────┐┌────────┐│
│  │   Puma (web)   │  │  │  │Agent C.││Agent C.││
│  └────────────────┘  │  │  └────────┘└────────┘│
│  ┌────────────────┐  │  │  ┌────────┐┌────────┐│
│  │ GoodJob Worker │  │  │  │Agent C.││Agent C.││
│  └────────────────┘  │  │  └────────┘└────────┘│
│  ┌────────────────┐  │  │  ┌────────┐┌────────┐│
│  │Temporal Worker │  │  │  │Agent C.││Agent C.││
│  └────────────────┘  │  │  └────────┘└────────┘│
└──────────┬───────────┘  └──────────────────────┘
           │
  ┌────────┴────────┐
  │   PostgreSQL    │
  │  (shared or     │
  │   dedicated)    │
  └─────────────────┘
```

```env
WEB_CONCURRENCY=2
RAILS_MAX_THREADS=5
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
GOOD_JOB_QUEUES=default:3;maintenance:2;metrics:2;knowledge:2;low_priority:1
GOOD_JOB_POLL_INTERVAL=3
TEMPORAL_WORKFLOW_SLOTS=20
TEMPORAL_ACTIVITY_SLOTS=8
TEMPORAL_LOCAL_ACTIVITY_SLOTS=4
DB_POOL=30
```

**Resource budget:**

- Max concurrent containers: **8-12** across Docker hosts
- PostgreSQL connections: ~60 total (2 web workers × 30 pool + 1 GoodJob + 1 Temporal)
- Recommended PostgreSQL `max_connections`: 100

### Large — Organization

**Profile:** 8+ vCPU, 16+ GB RAM, multi-server, 50+ concurrent agent runs.

Dedicated hosts for each process type. Horizontal scaling for web and Temporal workers.

```
┌────────────┐ ┌────────────┐ ┌────────────┐
│  Web Host  │ │  Web Host  │ │  Web Host  │
│   (Puma)   │ │   (Puma)   │ │   (Puma)   │
└─────┬──────┘ └─────┬──────┘ └─────┬──────┘
      └───────────────┼───────────────┘
                      ▼
             ┌────────────────┐
             │  Load Balancer │
             └────────────────┘

┌────────────────┐  ┌────────────────┐
│ GoodJob Worker │  │ GoodJob Worker │
│   (external)   │  │   (external)   │
└────────┬───────┘  └────────┬───────┘
         └───────────┬───────┘
                     ▼
            ┌────────────────┐
            │   PostgreSQL   │
            │  (dedicated,   │
            │   tuned)       │
            └────────────────┘

┌────────────────┐  ┌────────────────┐
│Temporal Worker │  │Temporal Worker │
│  + Docker Host │  │  + Docker Host │
└────────────────┘  └────────────────┘
```

```env
WEB_CONCURRENCY=auto
RAILS_MAX_THREADS=5
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=20
GOOD_JOB_QUEUES=default:6;maintenance:4;metrics:4;knowledge:4;low_priority:2
GOOD_JOB_POLL_INTERVAL=1
TEMPORAL_WORKFLOW_SLOTS=50
TEMPORAL_ACTIVITY_SLOTS=16
TEMPORAL_LOCAL_ACTIVITY_SLOTS=8
DB_POOL=50
```

**Resource budget:**

- Max concurrent containers: **50+** across Docker hosts (16 GB RAM per host supports ~3-4 containers)
- PostgreSQL connections: set `max_connections` to 200-300
- Consider PgBouncer for connection pooling at this scale

## Capacity Planning

### Users to Resources

Use this table as a starting point. Actual resource needs depend on issue complexity,
agent run frequency, and concurrent usage patterns.

| Active Users | Concurrent Runs | Tier | vCPU | RAM | DB Connections |
|-------------|-----------------|------|------|-----|----------------|
| 1-5 | 1-4 | Small | 2 | 4-8 GB | 20 |
| 5-20 | 5-15 | Small-Medium | 4 | 8-16 GB | 30-50 |
| 20-50 | 15-30 | Medium | 4-8 | 16-32 GB | 50-100 |
| 50-100 | 30-60 | Medium-Large | 8-16 | 32-64 GB | 100-150 |
| 100+ | 60+ | Large | 16+ | 64+ GB | 200+ |

### Key Formulas

**Docker host memory requirement:**

```
host_ram_for_containers = max_concurrent_containers × 4 GB
total_host_ram = host_ram_for_containers + 2 GB (OS + services overhead)
```

**Database connection budget:**

```
total_connections =
  (web_instances × WEB_CONCURRENCY × DB_POOL)
  + (goodjob_workers × DB_POOL)
  + (temporal_workers × DB_POOL)
  + 10  # headroom for migrations, console, monitoring
```

**Activity slots across Temporal workers:**

```
total_agent_activity_slots = num_agent_workers × TEMPORAL_ACTIVITY_SLOTS
total_poll_activity_slots = num_poll_workers × TEMPORAL_POLL_ACTIVITY_SLOTS
max_concurrent_agent_runs ≈ total_agent_activity_slots
```

### When to Scale

| Metric | Threshold | Action |
|--------|-----------|--------|
| Web response time p95 | > 500ms | Add web instances or increase `WEB_CONCURRENCY` |
| GoodJob default queue latency | > 30s | Increase `GOOD_JOB_MAX_THREADS` or add worker |
| GoodJob error rate | > 5% | Investigate errors (not a scaling issue) |
| Temporal activity schedule-to-start | > 60s | Increase `TEMPORAL_ACTIVITY_SLOTS` or add worker |
| Temporal workflow task backlog | Growing | Increase `TEMPORAL_WORKFLOW_SLOTS` |
| PostgreSQL active connections | > 80% of `max_connections` | Increase `max_connections` or add PgBouncer |
| Docker host memory usage | > 85% | Add Docker host or reduce container memory |
| Docker host CPU usage | Sustained > 90% | Add Docker host |

## Horizontal Scaling

### Web Servers

Puma web servers are stateless and scale horizontally behind a load balancer.
Each instance needs its own `DB_POOL` allocation.

1. Deploy additional web instances with the same image and configuration
2. Add them to your load balancer (sticky sessions not required)
3. Ensure total DB connections across all instances fits within `max_connections`

### GoodJob Workers

GoodJob workers coordinate through PostgreSQL advisory locks, so multiple
workers can run safely in parallel.

1. Set `GOOD_JOB_EXECUTION_MODE=external` on all instances
2. Deploy additional worker processes (`bin/jobs`)
3. Only one worker should have `GOOD_JOB_ENABLE_CRON=true` to avoid duplicate cron runs
4. Each worker needs its own `DB_POOL` allocation

### Temporal Workers

Temporal workers register on a shared task queue and the Temporal server
distributes work across all registered workers.

1. Deploy additional Temporal worker processes (`bin/temporal_worker`)
2. Set `TEMPORAL_WORKER_MODE=agent` or `TEMPORAL_WORKER_MODE=poll` when you want dedicated worker pools per queue
3. Workers serving the same queue share the same task queue name and Temporal load-balances across them
4. Each worker process needs its own `DB_POOL` and Docker Engine access
5. Total activity slots = sum across workers serving that queue

### PostgreSQL

For most deployments, a single PostgreSQL instance is sufficient.
At large scale, consider:

- **Connection pooling** (PgBouncer) to multiplex application connections
- **Read replicas** for dashboard queries and reporting
- **Vertical scaling** (more CPU/RAM) before horizontal for PostgreSQL
- **Vacuuming tuning** for GoodJob's high-write job tables

## PostgreSQL Tuning

Key PostgreSQL settings to adjust as you scale:

| Setting | Small | Medium | Large |
|---------|-------|--------|-------|
| `max_connections` | 50 | 100 | 300 |
| `shared_buffers` | 256 MB | 1 GB | 4 GB |
| `effective_cache_size` | 512 MB | 3 GB | 12 GB |
| `work_mem` | 4 MB | 8 MB | 16 MB |
| `maintenance_work_mem` | 64 MB | 256 MB | 512 MB |

Monitor connection usage:

```sql
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';
SELECT count(*) FROM pg_stat_activity;
```

## Network Architecture

Paid uses two Docker networks to isolate agent traffic:

| Network | Purpose | Internet Access |
|---------|---------|-----------------|
| `paid_internal` | Rails, Temporal, PostgreSQL, Qdrant, subscription-auth agent runs, direct-outbound provider runs | Yes |
| `paid_agent` | Proxy-mode agent container execution | No (internal only) |

Proxy-mode agent containers communicate with external services through the secrets
proxy and the Git credential proxy. Subscription-auth and direct-outbound provider
runs are explicit exceptions: they use `paid_internal` so their provider CLIs can
reach upstream APIs directly. Service containers are placed on the same network
as the agent run that needs them.

## Health Checks and Graceful Shutdown

### Health Check Endpoints

The web (Puma) process exposes distinct liveness and readiness endpoints for
cloud schedulers and load balancers:

| Endpoint | Purpose | Returns 503 when |
|----------|---------|-------------------|
| `GET /live` | Liveness — process is alive | Never (200 if the process responds) |
| `GET /ready` | Readiness — can serve traffic | DB, Redis, or Temporal unreachable |
| `GET /up` | Combined (Rails default) | App fails to boot |
| `GET /health/readiness` | Alias for `/ready` | Same as `/ready` |
| `GET /health/liveness` | Alias for `/live` | Same as `/live` |
| `GET /health/services` | Legacy Qdrant-only check | Qdrant unreachable |

**Recommended probe configuration:**

- **Liveness probe** → `GET /live`. A failed liveness probe triggers a restart.
  Use a generous failure threshold (3 consecutive failures) to avoid restarts
  during transient blips.
- **Readiness probe** → `GET /ready`. A failed readiness probe stops traffic
  routing but does not restart the process. Use this for rolling deploys.

The readiness check verifies:
- **Database** — `SELECT 1` succeeds
- **Migrations** — no pending migrations
- **Redis** — `PING` returns `PONG` (2s timeout)
- **Temporal** — client connection is live (2s timeout)
- **Qdrant** — client `healthy?` (only when `QDRANT_URL` is set)

Each check is independently reported in the JSON response. A process with
unreachable dependencies reports `not_ready` (HTTP 503), not crashed.

### Worker Readiness Signals

Background worker processes (`bin/temporal_worker`, `bin/jobs`) do not serve
HTTP. They signal readiness via a file-based flag:

- On startup, the worker writes a ready-flag file to `WORKER_READINESS_FILE`
  (default: `#{Dir.tmpdir}/paid-worker-ready`).
- On SIGTERM (graceful shutdown), the file is removed, signaling the
  orchestrator that the worker is draining.

An orchestrator or sidecar checks readiness with:

```bash
test -f "$WORKER_READINESS_FILE" && exit 0 || exit 1
```

During a rolling deploy, wait for the new worker's ready flag before removing
the old worker.

### Termination Grace Periods

When a cloud scheduler sends SIGTERM, each worker process initiates a graceful
shutdown with a bounded window, then force-exits if the shutdown does not
complete. The scheduler's **termination grace period** must be at least as long
as the total force-exit timeout for each worker process type:

| Process | Graceful window | Force-exit buffer | Total | Grace period ≥ |
|---------|----------------|-------------------|-------|----------------|
| Temporal worker | `TEMPORAL_GRACEFUL_SHUTDOWN_PERIOD` (30s) | `TEMPORAL_FORCE_EXIT_BUFFER_SECONDS` (10s) | 40s | **40s** |
| GoodJob worker | `GOOD_JOB_SHUTDOWN_TIMEOUT` (25s) | `GOOD_JOB_FORCE_EXIT_BUFFER_SECONDS` (10s) | 35s | **35s** |
| Web (Puma) | `WORKER_SHUTDOWN_TIMEOUT` (30s) | — | 30s | **30s** |

**Kubernetes:** set `terminationGracePeriodSeconds` to at least **45** (max
worker total + headroom) on all worker pod templates.

```yaml
spec:
  terminationGracePeriodSeconds: 45
```

**Kamal / Docker:** the default Docker stop timeout is 10s — too short. Set
`stop_timeout` on each service to at least 45s:

```yaml
# config/deploy.yml (Kamal)
server:
  host: ...
  options:
    stop_timeout: 45
```

If you tune the graceful shutdown periods up (e.g., for very long-running
activities), increase the termination grace period proportionally.
