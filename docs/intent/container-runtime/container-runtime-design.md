---
parent: PAID
prefix: CONTAINER-RUNTIME
---

# Low-Level Design: Container Runtime

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> implemented container RDRs [RDR-004](../../rdrs/RDR-004-container-isolation.md),
> [RDR-019](../../rdrs/RDR-019-remote-container-execution.md),
> [RDR-020](../../rdrs/RDR-020-service-container-architecture.md),
> [RDR-043](../../rdrs/RDR-043-zero-config-docker-capacity-autoscaling.md), and
> [RDR-048](../../rdrs/RDR-048-multi-host-docker-backend-support.md). This
> segment also records the still-shipped legacy residue from superseded
> [RDR-005](../../rdrs/RDR-005-git-worktree-management.md).

## Purpose

Paid's container runtime is the shipped boundary between the control plane and
untrusted agent execution. The current model is no longer "host worktree bind
mounted into a local container for every run." Normal agent runs now use a
backend-selected Docker container, a per-run named workspace volume, and an
in-container clone, while multi-host placement, service-container routing, and
capacity admission all operate against the selected backend.

This segment captures the current runtime contract so brownfield LID coverage
matches the implementation rather than the older worktree-first design text.

## Runtime Contract

### Isolation and workspace provisioning

`Containers::Provision` owns the normal agent-run container lifecycle. It:

- validates backend compatibility before provisioning,
- creates or reuses the backend-selected Docker network,
- uses a per-run named Docker volume (`paid-workspace-<agent_run_id>`) when
  `worktree_path` is blank so the repo clone happens inside the container,
- seeds runner credentials and applies network restrictions after start, and
- records the backend-owned `container_host` only from the created container.

An explicit `worktree_path` is still accepted as a legacy compatibility input
for bind-mount and maintenance flows, but host-created worktrees are no longer
the default execution workspace for normal agent runs.

### Host selection and lifecycle routing

`Containers::ResolveHostForRun` converts explicit or preferred host choices
into run attributes. `Containers::BackendScheduler` then filters candidate
hosts by compatibility and readiness, with optional first-healthy or
capacity-aware fallback.

In multi-host mode, `container_host` is intentionally not treated as an eager
claim-time placement field. During the queue claim window, the admitted host is
stored in `external_metadata["planned_container_host"]`, and the real
`container_host` is persisted only once a backend creates or claims a concrete
resource.

`AgentRun.active_count_for_host` and `AgentRun#workspace_volume_host` mirror
that rule: before a real container records ownership, per-host admission and
workspace-volume cleanup both route by the planned host metadata instead of
charging blank rows to the local backend.

### Service-container orchestration

`Containers::ServiceProvisioner` manages project service containers on the same
backend/network as the agent run. It records `service_container_ids` on the run
before startup so concurrent cleanup can count the run, reuses healthy running
containers when possible, generates per-service environment variables, and only
stops containers when no in-flight runs still reference them.

The backend decision for service containers follows the selected run backend or
the persisted service-container host so reuse, metrics, reconciliation, and
cleanup stay routed to the daemon that actually owns the container.

### Capacity snapshots and admission

`Capacity::DockerSnapshot` is the per-backend Docker visibility layer for
runtime admission. It classifies visible Docker usage into four buckets:

- Paid control plane
- Paid agent containers
- Paid service containers
- other Docker workloads

Snapshots are cached briefly and are allowed to degrade conservatively when
Docker reads time out, sampling exceeds its shared budget, or cached data goes
stale.

`Capacity::RunAdmission` consumes those snapshots together with hard
host/user/project/create-PR ceilings. Auto mode may admit against Docker memory
budget when confidence is good, but degraded or missing snapshot paths fall
back conservatively, and sampling-budget exhaustion fails closed for that
admission pass.

## Accepted Divergence

RDR-005's host-side "one git worktree per agent run" model is superseded for
normal agent execution. Paid still keeps `Worktree` records and host-side
worktree flows for legacy metadata, conflict/maintenance paths, and explicit
bind-mount compatibility, but those legacy paths are not the current runtime
requirement for ordinary agent runs and should not be reintroduced as the
default design.

## Runner abstraction boundary (RDR-054)

`ExecutionRunners` defines the domain-oriented runner contract that will
replace direct Docker API access in orchestration code. The interface is driven
by what `Containers::Provision` actually does today, not speculative
generalization, and is reviewed against the coupling inventory (#3337) to
confirm coverage.

- `ExecutionRunners::Base` is the abstract interface: `provision`, `start`,
  `running?`, `reconnect`, `status`, `cancel`, `cleanup`, `.compatible?`, `.ping`. Method
  names and parameters never reference Docker concepts.
- A runner owns the complete execution environment (primary workload, sidecars,
  services, network, workspace) as a single lifecycle, plus the watchdog logic
  (startup, idle, wall-clock, heartbeat, abort-pattern detection).
- Value objects consolidate existing patterns: `RunSpec` (what to run),
  `RunnerHandle` (opaque, JSON-serializable reference for recovery),
  `ExecutionResult` (outcome, including OOM and timeout classification),
  `ExecutionStatus` (lifecycle status: `:running | :exited | :oom_killed |
  :not_found`, returned by `Base#status`), `NetworkingPolicy` (adapts
  `NetworkPolicy::NetworkContract`, drops the Docker network name),
  `ServiceDeclaration`, and `ComputeRequirements`.
- `ExecutionRunners::LocalDockerRunner` implements `Base` as a thin adapter over
  `Containers::Provision`: `#provision`/`#start`/`#running?`/`#reconnect`/`#status`/
  `#cancel`/`#cleanup` translate `RunSpec`/`RunnerHandle` to `Containers::Provision.new`,
  `#execute`, `#container_running?`, `#container_status`, `Containers::Provision.reconnect`,
  and `#cleanup` calls, and translate
  `Containers::Provision::Result` and its error classes into `ExecutionResult`
  and the `ExecutionRunners` error hierarchy. `RunnerHandle#metadata` carries
  the `agent_run_id`, `worktree_path`, and `environment` needed to reconnect a
  handle recovered after worker restart, since only the handle (not the
  original `RunSpec`) is passed back into later lifecycle calls.
  `Containers::Provision` itself is not modified, and services/sidecars are not
  yet translated (tracked separately). `ExecutionRunners.resolve` currently
  always returns `LocalDockerRunner`, since every existing backend (local
  Docker, remote Docker, Swarm) is a Docker transport.

### Persisted handle and recovery (RDR-054)

A `runner_handle` jsonb column on `agent_runs` (alongside, not replacing,
`container_id`/`container_host`) stores the serialized `RunnerHandle` so a
Temporal activity retry can recover after a worker restart or failover. When a
retry finds a persisted `runner_handle`, `AgentRun#provision_via_runner` routes
through `reuse_or_reconcile_via_runner`: it loads the handle via
`RunnerHandle.from_record`, checks `runner.running?`, and either reuses the
still-running environment or cleans up a dead/missing one before provisioning
fresh. A data migration backfills `runner_handle` from existing
`container_id` + `container_host` so legacy rows are immediately recoverable.
The column is also added to `container_pool_entries` and `service_containers`
so future pool and service-container code can store runner handles.

### Workspace strategy isolation (#3342)

Workspace storage is expressed as a provider-neutral `WorkspaceStrategy` on
`RunSpec`, isolating workspace assumptions from Docker volumes and bind mounts
so a future remote runner (Fly, Cloud Run) can substitute object storage or
ephemeral disk without changing orchestration code.

**This PR (implemented).** Volume and bind translation; volume-name isolation;
orphan-cleanup delegation.

- `WorkspaceStrategy` carries `mode` (`:named_volume | :bind_mount | :ephemeral
  | :object_storage`), the workload `mount_point`, an opaque `reference`
  (volume name, host path, or storage URI — nil until provisioned), the
  `writable_dirs` the workload needs (`WritableDir`: path, size, mode, exec),
  and a `heartbeat` `HeartbeatConfig`. The default writable directories
  (`/tmp`, `/home/agent/.cache`) and the heartbeat `mount_point` are declared
  on the strategy as the provider-neutral shape; runner-specific credential
  tmpfs mounts (e.g. `~/.claude`, `~/.codex`) remain a Docker-implementation
  detail owned by `Containers::Provision`.
- `LocalDockerRunner` translates the `:named_volume` and `:bind_mount` modes
  to Docker operations: `:named_volume` constructs the per-run volume name
  (`paid-workspace-<id>`) inside the runner via `workspace_volume_name_for`
  and mounts it via `Containers::Provision`; `:bind_mount` forwards the
  host-path reference as `Containers::Provision#worktree_path`. Volume-name
  construction lives in the runner, so no orchestration code or the domain
  model builds Docker volume names.
- `RunnerHandle#workspace_ref` stores the opaque workspace reference for
  recovery and cleanup across the provision → start → cleanup lifecycle.
- `AgentRun#cleanup_orphaned_workspace_volume` delegates volume-name
  construction and deletion to `LocalDockerRunner#cleanup_workspace_reference`
  rather than constructing `paid-workspace-<id>` in the model.

**Deferred (see CONTAINER-RUNTIME-012, -013, -014).** Writable tmpfs layout,
heartbeat ownership, pool workspace through the runner.

- `WorkspaceStrategy#writable_dirs` is declared on the strategy with a
  `WritableDir#docker_tmpfs_options` helper that produces the same option
  string Docker consumes, but `Containers::Provision#host_config` still
  hardcodes its own `Tmpfs` block; the runner does not yet translate the
  strategy's writable dirs into Provision calls (CONTAINER-RUNTIME-012).
- `WorkspaceStrategy#heartbeat` (`HeartbeatConfig`) declares the heartbeat
  mount point on the strategy, but `Containers::Provision#prepare_heartbeat_dir!`
  still owns the host temp-dir vs. in-container tmpfs selection from the
  backend's host-path capability, and callers still pass `heartbeat_path:` to
  `LocalDockerRunner#start` (CONTAINER-RUNTIME-013).
- Pool workspace management (`paid-pool-workspace-<pool_entry_id>`) still
  lives in `Containers::PoolManager` and `Containers::Provision`; the runner
  does not yet own pool workspace construction or cleanup (CONTAINER-RUNTIME-014).

`Containers::Provision` is intentionally unchanged in this PR: the existing
default workspace strategy (named volumes with in-container clone), host
bind-mount support, and all provision-side workspace/heartbeat tests are
preserved until the deferred specs land.

### Execution resource ledger reconciliation (#3411)

Provision-time `runner_handle` persistence solves retry-time recovery for a
single workflow attempt, but it is not enough to keep cleanup durable across
provider drift, worker death, or reconciliation gaps. A separate
`execution_resources` ledger stores the provider-owned execution environments
Paid believes exist, plus cleanup state that survives job retries and workflow
restarts.

- Provisioning (runner and legacy Docker paths) upserts a single `environment`
  ledger row per `AgentRun`. The row records the provider identity
  (`runner_type`, `host`, `identifier`), the serialized `runner_handle` for
  handle-based fallback cleanup, and the opaque `workspace_ref`.
- Cleanup transitions the row from `active` to `cleanup_pending` before the
  provider call. If cleanup succeeds, the row becomes `cleaned`. If cleanup
  fails, the row remains `cleanup_pending` with durable failure metadata
  (`cleanup_attempts`, `next_cleanup_at`, `last_cleanup_error*`) so later
  reconciliation can retry with backoff even after the run record has cleared
  its direct container references.
- `ExecutionResourceReconciliationJob` groups ledger rows by runner/provider and
  asks the runner for a tagged resource listing when supported. That lets Paid
  compare “what the ledger says exists” against “what the provider still
  reports”, mark provider-missing rows cleaned, retry `cleanup_pending`
  resources that are still present, and adopt tagged-but-untracked orphan
  resources into the ledger before cleaning them up.
- Providers without tag/list support do not block migration. Reconciliation
  falls back to `runner_handle`-based cleanup for `cleanup_pending` rows and
  marks those passes `reduced_confidence`, because the system cannot prove the
  provider inventory matches the ledger and cannot adopt unknown orphans from a
  direct listing.
- Existing Docker janitors remain in place. `DockerOrphanCleanupJob` and
  `AgentRunResourceJanitorJob` still provide immediate cleanup during the
  migration, while the ledger reconciliation loop becomes the durable source of
  truth for retries and orphan adoption.

## References

- `app/services/containers/provision.rb`
- `app/services/execution_runners.rb`
- `app/services/execution_runners/base.rb`
- `app/services/execution_runners/local_docker_runner.rb`
- `app/models/execution_resource.rb`
- `app/services/execution_resources/reconcile.rb`
- `app/jobs/execution_resource_reconciliation_job.rb`
- `app/services/containers/resolve_host_for_run.rb`
- `app/services/containers/backend_scheduler.rb`
- `app/services/containers/service_provisioner.rb`
- `app/services/capacity/docker_snapshot.rb`
- `app/services/capacity/run_admission.rb`
- `app/models/agent_run.rb`
- `spec/services/containers/provision_spec.rb`
- `spec/services/execution_runners_spec.rb`
- `spec/services/execution_runners/base_spec.rb`
- `spec/services/execution_runners/local_docker_runner_spec.rb`
- `spec/support/shared_examples/execution_runner_contract.rb`
- `spec/services/containers/service_provisioner_spec.rb`
- `spec/services/capacity/docker_snapshot_spec.rb`
- `spec/services/capacity/run_admission_spec.rb`
- `spec/services/containers/backend_scheduler_spec.rb`
- `spec/requests/agent_runs_spec.rb`
- `spec/jobs/process_run_queue_job_spec.rb`
