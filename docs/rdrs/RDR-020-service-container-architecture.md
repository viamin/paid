# RDR-020: Service Container Architecture

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-03-28
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #216, #245, #246, #248
- **Related Tests**: `spec/services/containers/service_provisioner_spec.rb`, `spec/models/service_container_spec.rb`, `spec/jobs/docker_orphan_cleanup_job_spec.rb`

## Problem Statement

AI agents running in isolated Docker containers often need access to external services such as PostgreSQL, Redis, or Selenium for running tests and setup commands. Without service containers:

1. Agents cannot run integration tests that require a database
2. Agents cannot test code that depends on Redis caching or queuing
3. Agents cannot run browser-based tests requiring Selenium/Chromium
4. Each agent would need to install and manage services inside its own container, wasting resources and adding complexity

Requirements:

- Service containers must be reachable from agent containers without exposing them to the public internet
- Multiple concurrent agent runs should share service containers to conserve resources
- Operators must control which Docker images are allowed to run as services
- Service containers must be cleaned up when no longer needed
- The system must handle container failures, name conflicts, and Docker state drift gracefully

## Context

### Background

Paid already isolates agent execution in Docker containers connected to a restricted network (`paid_agent` or `paid_internal`; see RDR-004). Service containers extend this model by placing additional Docker containers on the same network so agents can reach them by hostname.

The design builds on Paid's existing container management patterns: Docker API integration, network policy enforcement, and the secrets proxy architecture (RDR-006).

### Technical Environment

- Docker Engine on the host, accessed via `docker-api` gem
- Two Docker networks: `paid_agent` (restricted, API-key mode) and `paid_internal` (subscription-auth mode)
- PostgreSQL database storing service container definitions and metrics
- GoodJob for background jobs (metrics collection, reconciliation, orphan cleanup)
- Temporal for workflow orchestration of agent runs

## Research Findings

### Key Design Questions

1. **Shared vs. per-run containers**: Creating a fresh service container per agent run is simple but wasteful. Agents in the same project typically need the same services. Sharing containers across concurrent runs reduces startup latency and resource consumption.

2. **Cleanup safety**: When multiple agent runs share a container, stopping it prematurely kills services for still-active runs. A reference counting mechanism is needed to determine when a container is safe to remove.

3. **Image security**: Allowing arbitrary Docker images would let operators (or compromised accounts) run untrusted code on the host. An allowlist restricts images to vetted choices.

4. **Network placement**: Service containers must be on the same Docker network as the agent container. The network selection depends on the authentication mode (`paid_agent` for API-key, `paid_internal` for subscription-auth).

### Discovery: Docker State Drift

Docker containers can stop unexpectedly (OOM kills, Docker daemon restarts, manual intervention). The database status can drift from the actual Docker state. Three mechanisms address this:

- **ServiceContainerReconciliationJob**: Runs every 5 minutes, detects containers marked "running" in the database but actually stopped in Docker, and corrects the status.
- **DockerOrphanCleanupJob**: Runs every 5 minutes, finds Docker containers labeled `paid.service_container=true` with zero active agent runs, and removes them.
- **Provisioner liveness check**: Before reusing a "running" container, the provisioner verifies the Docker container is actually alive. If not, it re-provisions.

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DOCKER HOST                                      │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │              Docker Network (paid_agent / paid_internal)       │  │
│  │                                                                │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │  │
│  │  │  Agent        │  │  PostgreSQL  │  │  Redis           │    │  │
│  │  │  Container    │  │  Container   │  │  Container       │    │  │
│  │  │              │  │              │  │                  │    │  │
│  │  │  DATABASE_URL │  │  Port: 5432  │  │  Port: 6379     │    │  │
│  │  │  REDIS_URL   │──│  Name: proj- │──│  Name: proj-    │    │  │
│  │  │  (injected)  │  │   postgres   │  │   redis          │    │  │
│  │  └──────────────┘  └──────────────┘  └──────────────────┘    │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │              Paid Application (Rails)                          │  │
│  │                                                                │  │
│  │  ServiceProvisioner ─── provision / cleanup                   │  │
│  │  NetworkPolicy ──────── network selection                     │  │
│  │  Background Jobs ────── metrics, reconciliation, orphans      │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Model

```
Project ──< ProjectServiceContainer >── ServiceContainer
                                              │
                                              ├── service_container_metrics
                                              │
AgentRun.service_container_ids (JSONB array) ─┘
AgentRun.service_environment (JSONB hash)
```

- **ServiceContainer**: Stores the image, name, port, env, status, and Docker container ID.
- **ProjectServiceContainer**: Join table associating projects with their service containers.
- **AgentRun.service_container_ids**: JSONB array recording which service containers were provisioned for a run. Used for reference counting.
- **AgentRun.service_environment**: JSONB hash of generated environment variables passed to the agent container.

### Provisioning Flow

```
1. ProvisionServicesActivity.execute(agent_run_id)
       │
       ▼
2. ServiceProvisioner.provision(agent_run)
       │
       ├── Record association: agent_run.service_container_ids = [sc1.id, sc2.id]
       │
       ├── For each service container (with row-level lock):
       │       │
       │       ├── If running and Docker container alive → reuse
       │       │
       │       ├── If running but Docker container dead → re-provision
       │       │
       │       └── If stopped → pull image, create container, start, health check
       │
       └── Generate env vars and store in agent_run.service_environment
              │
              ▼
3. Agent container receives env vars (DATABASE_URL, REDIS_URL, etc.)
```

### Reference Counting and Cleanup

Containers are shared across agent runs within a project. The cleanup strategy:

1. **Early association**: `provision()` writes `service_container_ids` to the agent run **before** starting containers. This ensures concurrent cleanup operations count the run even during provisioning.

2. **Safe cleanup**: `cleanup(agent_run)` checks `active_agent_run_count` for each container. Only containers with zero active runs are stopped.

3. **Reference count query**: Uses PostgreSQL JSONB containment (`@>`) to count active runs referencing a container:

   ```ruby
   AgentRun.active
     .where(project_id: project_ids)
     .where("service_container_ids @> ?", [id].to_json)
     .count
   ```

4. **Orphan cleanup**: `DockerOrphanCleanupJob` catches containers missed by normal cleanup (e.g., due to process crashes).

### Image Allowlist

Operators control which Docker images can be used as service containers:

- **Storage**: `UserSetting#allowed_service_images` (JSONB array) per admin/owner user
- **Defaults**: `postgres:16`, `redis:7-alpine`, `selenium/standalone-chromium:latest`
- **Validation**: `ServiceContainer` validates the image against the union of allowlists from account admins/owners
- **Scoping**: On update, validation is scoped to admins of the container's associated project accounts
- **Configuration**: Admins manage the allowlist via the user settings UI (comma-separated input)

### Environment Variable Injection

The provisioner generates well-known environment variables based on image type:

| Image Pattern | Generated Variables |
|---------------|-------------------|
| `postgres`    | `DATABASE_URL=postgres://agent:agent@<name>:5432/agent_test` |
| `redis`       | `REDIS_URL=redis://<name>:6379` |
| `selenium`    | `SELENIUM_URL=http://<name>:4444` |
| `chromium`    | `SELENIUM_URL=http://<name>:4444` |
| _(other)_     | `SERVICE_<NAME>_HOST=<name>`, `SERVICE_<NAME>_PORT=<port>` |

PostgreSQL containers use safe defaults (`agent`/`agent`/`agent_test`) that can be overridden via the container's `env` JSON field.

### Resource Limits

Each service container runs with bounded resources to prevent a single service from starving the host:

| Image Pattern | Memory | CPU (quota/period) | PIDs |
|---------------|--------|--------------------|------|
| `postgres`    | 2 GB   | 1 CPU              | 200  |
| `redis`       | 1 GB   | 1 CPU              | 100  |
| `selenium`    | 2 GB   | 2 CPUs             | 300  |
| `chromium`    | 2 GB   | 2 CPUs             | 300  |
| _(default)_   | 1 GB   | 1 CPU              | 200  |

Memory swap is set equal to memory (no swap) to prevent OOM thrashing.

### Health Checking

Dual-mode health checking with a 30-second timeout:

1. **Docker HEALTHCHECK**: If the image defines a HEALTHCHECK (e.g., Postgres with `pg_isready`), the provisioner monitors the Docker health status.
2. **TCP port probe**: If no Docker HEALTHCHECK is configured, falls back to probing the service port via TCP.

The provisioner also configures a Docker HEALTHCHECK for Postgres images automatically.

### Background Jobs

| Job | Schedule | Purpose |
|-----|----------|---------|
| `ServiceContainerMetricsCollectionJob` | On-demand, self-rescheduling | Collects CPU/memory metrics from running containers |
| `ServiceContainerReconciliationJob` | Every 5 minutes | Detects DB/Docker status drift |
| `DockerOrphanCleanupJob` | Every 5 minutes | Removes containers with zero active runs |

## Alternatives Considered

### 1. Per-Run Ephemeral Containers

Start a fresh service container for every agent run.

- **Pros**: Simple lifecycle, no sharing complexity, no reference counting needed
- **Cons**: Slow (image pull + startup per run), wasteful (duplicate Postgres instances), higher resource consumption
- **Rejected**: Unacceptable startup latency for concurrent runs on the same project

### 2. Sidecar Containers (Docker Compose-style)

Bundle service containers as sidecars to the agent container.

- **Pros**: Lifecycle tied to agent container, simpler cleanup
- **Cons**: No sharing across concurrent runs, Docker-in-Docker complexity, harder to monitor independently
- **Rejected**: Defeats the resource-sharing goal

### 3. Host-Level Services

Run PostgreSQL, Redis, etc. directly on the host and expose to containers.

- **Pros**: Simpler management, no container overhead
- **Cons**: No isolation between projects, security risk (shared credentials), harder to customize per-project
- **Rejected**: Violates project isolation requirements

### 4. Environment Variable for Allowlist

Use a `SERVICE_CONTAINER_ALLOWED_IMAGES` environment variable instead of database-backed settings.

- **Pros**: Simple, familiar pattern
- **Cons**: Single global list (no per-account scoping), requires restart to change, no audit trail
- **Rejected**: Database-backed `UserSetting` provides per-account control and runtime updates via admin UI

## Trade-offs and Consequences

### Positive

- **Resource efficiency**: Shared containers reduce memory and CPU usage for concurrent runs
- **Fast provisioning**: Reusing running containers avoids image pull and startup latency
- **Operator control**: Image allowlist prevents unauthorized images from running on the host
- **Resilience**: Multiple mechanisms (reconciliation, orphan cleanup, liveness checks) handle state drift

### Negative

- **Complexity**: Reference counting and concurrent lock management add implementation complexity
- **Shared state risk**: A misbehaving agent could corrupt a shared database, affecting other concurrent runs
- **Docker dependency**: Tightly coupled to Docker API; harder to migrate to other container runtimes

### Risk Mitigations

- Row-level locking (`with_lock`) prevents race conditions during provisioning
- Health checks ensure containers are actually ready before agents connect
- Metrics collection enables monitoring of resource consumption per service container
- The reconciliation job catches edge cases where Docker and database states diverge

## Implementation Plan

### Files Modified/Created

| File | Change |
|------|--------|
| `app/services/containers/service_provisioner.rb` | Core provisioning and cleanup logic |
| `app/models/service_container.rb` | Model with allowlist validation and reference counting |
| `app/models/project_service_container.rb` | Join table model |
| `app/models/service_container_metric.rb` | Metrics model |
| `app/models/user_setting.rb` | `allowed_service_images` field |
| `app/services/network_policy.rb` | Service destination firewall rules |
| `app/temporal/activities/provision_services_activity.rb` | Temporal integration |
| `app/temporal/activities/cleanup_services_activity.rb` | Temporal integration |
| `app/jobs/service_container_metrics_collection_job.rb` | Metrics collection |
| `app/jobs/service_container_reconciliation_job.rb` | DB/Docker reconciliation |
| `app/jobs/docker_orphan_cleanup_job.rb` | Orphan container cleanup |
| `db/migrate/20260228120000_create_service_containers.rb` | Schema migration |

## Validation

### Test Scenarios

- Project with no service containers returns empty env hash
- Starts stopped containers and enqueues metrics collection
- Reuses running containers when Docker container is alive
- Re-provisions when Docker container is dead
- Cleans up Docker container on health check failure
- Handles container name conflicts by removing stale containers
- Adopts existing running containers with correct labels
- Generates correct environment variables for each image type
- Generates generic `SERVICE_*` vars for unknown images
- Image validation against allowlist (accepts allowed, rejects others)
- Orphan cleanup removes containers with zero active runs
- Reference counting prevents premature container removal

### Performance Validation

- Provisioning a running container (reuse path) adds minimal latency (<100ms)
- Health check timeout is bounded at 30 seconds
- Resource limits prevent service containers from consuming unbounded host resources

## References

### Dependencies

- [RDR-004: Container Isolation Strategy](RDR-004-container-isolation.md) — network model and firewall rules
- [RDR-006: Secrets Proxy Architecture](RDR-006-secrets-proxy.md) — proxy host referenced in firewall rules
- [docker-api gem](https://github.com/swipely/docker-api) — Docker Engine API client

### Related Issues

- #216 — Service container system implementation
- #245 — Admin UI for service container management
- #246 — Lifecycle management (reconciliation, orphan cleanup)
- #248 — Documentation (this RDR)
