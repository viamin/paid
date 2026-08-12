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
  `running?`, `cancel`, `cleanup`, `.compatible?`, `.ping`. Method names and
  parameters never reference Docker concepts.
- A runner owns the complete execution environment (primary workload, sidecars,
  services, network, workspace) as a single lifecycle, plus the watchdog logic
  (startup, idle, wall-clock, heartbeat, abort-pattern detection).
- Value objects consolidate existing patterns: `RunSpec` (what to run),
  `RunnerHandle` (opaque, JSON-serializable reference for recovery),
  `ExecutionResult` (outcome, including OOM and timeout classification),
  `NetworkingPolicy` (adapts `NetworkPolicy::NetworkContract`, drops the Docker
  network name), `ServiceDeclaration`, and `ComputeRequirements`.
- This issue defines the interface and objects only — no runner is implemented
  and no existing code is modified.

## References

- `app/services/containers/provision.rb`
- `app/services/execution_runners.rb`
- `app/services/execution_runners/base.rb`
- `app/services/containers/resolve_host_for_run.rb`
- `app/services/containers/backend_scheduler.rb`
- `app/services/containers/service_provisioner.rb`
- `app/services/capacity/docker_snapshot.rb`
- `app/services/capacity/run_admission.rb`
- `app/models/agent_run.rb`
- `spec/services/containers/provision_spec.rb`
- `spec/services/execution_runners_spec.rb`
- `spec/services/execution_runners/base_spec.rb`
- `spec/support/shared_examples/execution_runner_contract.rb`
- `spec/services/containers/service_provisioner_spec.rb`
- `spec/services/capacity/docker_snapshot_spec.rb`
- `spec/services/capacity/run_admission_spec.rb`
- `spec/services/containers/backend_scheduler_spec.rb`
- `spec/requests/agent_runs_spec.rb`
- `spec/jobs/process_run_queue_job_spec.rb`
