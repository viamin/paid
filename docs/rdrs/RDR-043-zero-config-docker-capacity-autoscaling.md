# RDR-043: Zero-Config Docker Capacity Autoscaling

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-06-28
- **Status**: Implemented
- **Type**: Operations + Architecture
- **Priority**: Medium
- **Related RDRs**: RDR-011 (Observability), RDR-019 (Remote Container Execution), RDR-020 (Service Container Architecture), RDR-033 (Worker Pool Scaling Algorithm)
- **Related Tests**: Container metrics tests, queue processor tests, scaling advisor tests, Docker backend tests, capacity-management system tests

## Implementation Status

Implemented. Tracking issue #2726 is closed as completed; implementation landed across #2741, #2747, #2744, #2757, #2797, and #2756.

Paid now has:

- `Capacity::DockerSnapshot` for Docker-visible CPU/memory, container classification, cached snapshots, confidence, and degraded fallback.
- Auto-capacity observe mode in the operations dashboard.
- `Capacity::RunAdmission` integrated with `ProcessRunQueueJob` and Temporal capacity checks.
- Static tenant/user/project/create-PR limits retained as hard ceilings when configured.
- `AgentRunResourceProfile` rollups for observed p50/p95/max memory, OOM counts, and recommended memory limits.
- Auto container memory-limit mode with OOM feedback, conservative upward tuning, and dampened downward tuning.
- `Capacity::Policy` defaults and guardrails for Docker Desktop, OrbStack, Linux Docker, CI, remote/shared backends, missing metrics, and exhausted Docker memory.

Operational caveat: implemented does not mean always active. Auto capacity deliberately degrades to manual behavior when Docker metrics are missing, stale, slow, or low-confidence; shared, managed, and remote Docker backends default to manual unless explicitly opted in. Existing users or deployments can also remain in manual run-concurrency or manual container-memory modes.

## Problem Statement

For a single user running Paid locally, `max_concurrent_runs` and container memory limits are difficult manual knobs. The user should not need to experiment with:

- how many agent runs can safely run in parallel;
- how much memory each agent container needs;
- how much capacity the Paid control plane needs;
- when to reduce concurrency after OOM kills or Docker pressure.

The desired behavior is:

> Paid should use as much of Docker's configured capacity as it can without making the local Paid stack unstable.

Docker Desktop, OrbStack, or the Docker daemon already represent the resource boundary chosen by the user. Paid should treat Docker's visible CPU and memory capacity as the hard budget, observe current container usage, and adapt agent-run admission plus container settings inside that budget.

## Context

### Deployment Scope

This RDR targets local, single-user, and single-tenant deployments where Paid owns the agent containers it starts and can inspect the Docker daemon used for those containers. It should not become the default behavior for managed multi-account deployments, shared Docker hosts, or remote Docker backends without a separate fairness and isolation policy.

In managed or multi-tenant environments, static tenant guardrails and/or deployment-level capacity controls remain authoritative unless a later RDR defines shared-capacity scheduling.

### Current Capacity Layers

Paid has two different kinds of capacity control:

- **Admission guardrails**: `max_concurrent_runs`, `max_parallel_agents_per_project`, `max_concurrent_create_pr_runs`, and related tenant/user limits determine whether another agent run may start.
- **Execution machinery**: GoodJob threads, Temporal worker slots, Docker containers, and service containers execute the work after it is admitted.

For local single-user operation, the most important scaling decision is admission: whether another expensive agent container should start now. Worker service replica scaling is secondary and usually irrelevant when the whole stack is running inside one Docker environment.

### Docker as the Capacity Boundary

Paid can inspect Docker-visible resources:

- daemon CPU count and memory capacity from `docker info`;
- running containers from `docker ps`;
- current CPU/memory usage from `docker stats`;
- per-container state and OOM status from `docker inspect`.

This lets Paid avoid host-level laptop introspection. It does not need to understand battery state, host memory pressure, or other non-Docker applications. Docker's configured capacity is the budget; Paid manages within that budget.

Docker access is a privileged operational capability. The implementation must treat Docker daemon access as local infrastructure authority, not as ordinary user data access. It must not expose unrelated container names, images, labels, environment, mounts, or logs to non-admin users.

### Control Plane vs Agent Work

In local Docker Compose-style deployments, Docker capacity is shared by:

- Paid Rails app;
- Postgres, Redis, Temporal, Qdrant, and other control-plane services;
- service containers;
- agent containers;
- potentially unrelated user Docker containers on the same daemon.

Paid should not reserve arbitrary "laptop headroom" outside Docker. It should subtract observed non-agent usage inside Docker and use the remaining capacity for agent runs. This protects the Paid control plane and any unrelated Docker workloads visible on the same daemon.

## Research Findings

### Existing Assets

Paid already has useful primitives:

- `AgentRun` queue and dispatch logic centralized in `ProcessRunQueueJob`.
- `AgentRun.has_run_capacity?` and tenant/user guardrails that can be replaced or supplemented by adaptive capacity.
- `ContainerMetric` and `ServiceContainerMetric` records for observed resource usage.
- Docker backend code that can be extended to read daemon capacity and inspect OOM state.
- Per-run container lifecycle records that can be tied to resource outcomes.
- `Scaling::WorkerPoolAdvisor` as a reference for cooldowns, bounds, and conservative decisions.

### Gaps

The missing pieces are:

- no model for effective computed concurrency;
- no resource-budget service that summarizes Docker capacity and current usage;
- no adaptive admission service that decides whether another run may start;
- no learned per-run memory estimate by project/runner/goal;
- no OOM feedback loop that raises container memory limits or lowers admission;
- no UI that explains "Auto capacity" in terms of Docker budget and current effective concurrency;
- no fallback behavior for environments where Docker capacity cannot be inspected.

### RDR-033 Is Insufficient

RDR-033 answers whether to add or remove workers given queue depth and worker utilization. It does not decide:

- how many agent containers fit in the current Docker budget;
- how much memory an agent container should receive;
- whether an OOM kill means lower concurrency, higher per-container limit, or both;
- how to protect the Rails/Temporal/Postgres control plane from agent containers.

RDR-033 can inform implementation style, but zero-config local capacity management needs a dedicated adaptive admission and resource-tuning layer.

## Recommendation

Implement zero-config Docker capacity autoscaling as the default local/single-tenant capacity mode.

Core decision:

> Paid should make `max_concurrent_runs` optional by introducing auto-managed run admission based on Docker's configured capacity, observed control-plane/container usage, and recent agent-run resource outcomes. Paid should also support auto-managed agent container memory limits that increase after OOM evidence and adjust conservatively from observed usage.

Manual limits should remain available for hosted, enterprise, and debugging scenarios, but the preferred local path should be `auto`. Auto mode should also account for existing project-level and goal/account-level admission caps so `max_concurrent_runs` is not removed only to leave another manual capacity knob as the effective local bottleneck.

## Proposed Design

### Capacity Modes

Introduce explicit capacity modes:

```text
run_concurrency_mode: manual | auto
project_concurrency_mode: manual | auto
container_memory_limit_mode: manual | auto
```

In `manual` mode, Paid keeps existing behavior.

In `auto` mode:

- `max_concurrent_runs` becomes an effective computed value, not a user-tuned setting.
- `max_parallel_agents_per_project` and create-PR/account concurrency caps either become effective computed values or explicit hard ceilings.
- dispatch decisions call an adaptive capacity service instead of comparing only against static guardrails.
- container memory limits come from learned estimates bounded by Docker capacity and configured hard caps.

### Docker Capacity Snapshot

Add a service, tentatively `Capacity::DockerSnapshot`, that reports:

```text
docker_cpu_count
docker_memory_bytes
paid_control_plane_memory_bytes
agent_memory_bytes
service_container_memory_bytes
unrelated_container_memory_bytes
available_memory_bytes
agent_container_count
oom_killed_container_count_recent
snapshot_at
confidence
```

The first implementation can use Docker CLI/API output:

- `docker info` for total CPUs and memory;
- `docker stats --no-stream` for current memory/CPU usage;
- `docker inspect` for OOM-killed state and configured container limits.

Capacity snapshots should be collected by a background job or memoized service with short TTLs and strict command/API timeouts. `ProcessRunQueueJob` must not run expensive Docker enumeration for every candidate run in the queue hot path. The queue processor should consume one cached snapshot per pass.

Prefer structured Docker API responses or JSON output over parsing human-formatted CLI tables. The CLI is acceptable as a first implementation boundary only if parsing is isolated and covered by fixture tests for Docker Desktop, OrbStack, and Linux Docker.

If Docker capacity is unavailable, stale, or low-confidence, Paid should fall back to conservative manual defaults and surface that auto mode is degraded.

### Adaptive Run Admission

Add a service, tentatively `Capacity::RunAdmission`, used by `ProcessRunQueueJob`.

Inputs:

- current Docker capacity snapshot;
- current active agent runs;
- queued run metadata: project, runner, goal;
- learned memory estimate for the queued run;
- minimum control-plane reserve derived from observed non-agent usage;
- recent OOM and memory-pressure events.

Output:

```text
allowed: true | false
reason
effective_max_concurrent_runs
estimated_memory_per_run_bytes
available_memory_bytes
```

The initial admission formula can be simple:

```text
agent_budget =
  docker_memory_bytes
  - observed_non_agent_container_memory
  - observed_unrelated_container_memory
  - control_plane_safety_margin

reserved_for_active_agents =
  sum(max(current_agent_memory_bytes, assigned_or_recommended_limit_bytes))

effective_max_concurrent_runs =
  floor(agent_budget / estimated_memory_per_run_bytes)

candidate_allowed =
  reserved_for_active_agents + estimated_memory_per_run_bytes <= agent_budget
```

Then clamp by hard safety bounds:

- never below 1 when the system is otherwise healthy;
- never above a high internal maximum unless explicitly configured;
- reduce or hold admission after recent OOM kills.

The control-plane safety margin should not be arbitrary laptop headroom. It should be based on observed non-agent Paid container usage plus a small multiplier or fixed minimum to absorb spikes.

Admission should budget active agent runs by committed or recommended memory, not only by current observed RSS. Current usage is often below peak early in a run; admitting based only on observed usage can overcommit Docker memory and create delayed OOM failures.

### Learned Memory Estimates

Add a model or persisted rollup, tentatively `AgentRunResourceProfile`, keyed by:

```text
account_id
project_id
runner_key
goal
```

Store:

```text
p50_memory_bytes
p95_memory_bytes
max_memory_bytes
sample_count
oom_count
last_oom_at
recommended_memory_limit_bytes
updated_at
```

Initial defaults should be conservative when no samples exist. As runs complete, update the profile from observed container metrics.

For project/runner/goal combinations with insufficient data, fall back in order:

1. runner+goal profile;
2. project profile;
3. account/global profile;
4. default estimate.

### Auto Container Memory Limits

When `container_memory_limit_mode` is `auto`, Paid sets each agent container's memory limit from the resource profile:

```text
recommended_memory_limit =
  max(default_minimum, p95_memory_bytes * safety_multiplier)
```

OOM feedback:

- If a container is OOM-killed, raise the recommended memory limit for that profile.
- If raising the limit would reduce available concurrency, prefer fewer concurrent runs over repeated OOM kills.
- If repeated OOMs continue near Docker capacity, stop increasing limits and classify the workload as capacity-blocked until Docker capacity increases or the user opts into a higher hard cap.

Do not lower limits aggressively. Downward tuning should require many successful samples and should be bounded to avoid oscillation.

### Queue Processor Integration

Replace or augment current capacity checks in `ProcessRunQueueJob`.

Current behavior checks user/account capacity with static limits. In auto mode, the queue processor should ask `Capacity::RunAdmission` before claiming/starting a run.

If admission is denied:

- leave the run queued;
- record the denial reason in logs/metrics;
- continue scanning only when another queued run might fit a different profile;
- avoid tight loops by caching the capacity snapshot for the job pass.

Static tenant/user hard caps may still apply as absolute ceilings when configured, but local auto mode should not require the user to choose the main concurrency number.

Existing Temporal capacity-check activities should use the same effective capacity result or clearly remain advisory. Otherwise the system can make inconsistent decisions between workflow preflight checks and the queue processor.

Auto mode must cover every admission path that can block local throughput: queue processor user capacity, project parallel capacity, and create-PR/account capacity. Any cap that remains manual should be labeled as an intentional hard ceiling, not as the primary capacity control.

### UI

Expose a simple capacity panel instead of asking the user to tune raw numbers.

Required UI:

- Capacity mode: `Auto` or `Manual`.
- Docker capacity detected: CPUs and memory.
- Current Docker usage split into Paid control plane, agents, service containers, and aggregate other-container usage.
- Effective max concurrent runs.
- Effective project/account hard ceilings when they constrain dispatch.
- Current running agent runs.
- Estimated memory per next run.
- Recent OOM events and resulting memory-limit changes.
- Container memory mode: `Auto` or `Manual`.
- Advanced manual override for users who need fixed limits.

The UI should explain decisions in operational terms:

```text
Auto capacity is allowing 3 concurrent runs because Docker has 6.2 GiB available for agents and this project currently estimates 2.0 GiB per run.
```

### Safety Requirements

- Docker capacity is the hard budget.
- Do not reserve laptop/host headroom beyond Docker's configured capacity.
- Protect the Paid control plane by subtracting observed non-agent container usage and adding a small spike margin.
- Use cached Docker capacity snapshots with strict timeouts; never block queue dispatch indefinitely on Docker inspection.
- Do not expose unrelated Docker container metadata beyond aggregate resource usage in normal UI.
- Prefer denying new runs over OOM-killing active runs.
- Prefer reducing concurrency over repeatedly raising memory limits to the full Docker budget.
- Detect and react to OOM-killed containers.
- Avoid oscillation with cooldowns and slow downward tuning.
- Keep manual overrides available.
- Surface degraded auto mode when Docker metrics are missing or unreliable.
- Never let unrelated Docker containers be invisible if they share the same daemon and appear in `docker stats`.
- Disable auto mode by default for shared, managed, or remote Docker environments unless a deployment explicitly opts in.

## Alternatives Considered

### Keep Static `max_concurrent_runs`

Continue requiring users to tune concurrency manually.

Rejected for local/single-user setups. The user should not need to discover machine-specific concurrency by trial and error, especially when the answer changes by project, runner, and Docker configuration.

### Host-Aware Laptop Autoscaling

Inspect host CPU, memory, battery, thermal state, and non-Docker applications.

Rejected for the first implementation. Docker already represents the capacity boundary the user configured. Host-aware logic is more complex, more platform-specific, and less predictable.

### Worker Service Replica Autoscaling First

Scale Temporal or GoodJob worker service replicas through Kubernetes/ECS/Compose.

Rejected as the primary local solution. Replica scaling is useful for managed/server deployments, but it does not solve the main local bottleneck: how many expensive agent containers to admit inside one Docker capacity budget.

### OOM-Only Tuning

Ignore proactive resource estimates and only react after OOM kills.

Rejected. OOM feedback is valuable, but using it alone creates a poor first-run experience and can destabilize the local control plane. Paid should combine conservative defaults, observed usage, and OOM feedback.

## Implemented Phases

### Phase 1: Observe and Explain

Implemented by #2741 and #2747:

1. Docker capacity snapshot service.
2. Container classification into Paid control plane, Paid agents, Paid service containers, and other Docker containers.
3. Snapshot caching, freshness, confidence, and timeout handling.
4. Operations capacity panel showing Docker budget, current usage, effective recommendation, and degraded mode.

### Phase 2: Auto Admission

Implemented by #2744:

1. Run-concurrency mode fields.
2. `Capacity::RunAdmission`.
3. Queue integration in `ProcessRunQueueJob`.
4. Temporal capacity-check activities aligned with the same effective capacity logic.
5. Static guardrails retained as optional hard ceilings.
6. Logs/metrics for denied dispatch due to Docker capacity.

### Phase 3: Resource Profiles

Implemented by #2757:

1. `AgentRunResourceProfile` rollups.
2. Profile refresh from completed run container metrics.
3. Fallback hierarchy for sparse data.

### Phase 4: Auto Memory Limits

Implemented by #2797:

1. Container memory-limit mode fields.
2. Recommended memory limits applied during container creation when auto mode is enabled.
3. OOM-killed containers feed profile updates.
4. Conservative upward tuning after OOM evidence.
5. Downward tuning only after sustained successful low-memory samples.

### Phase 5: Policy Refinement

Implemented by #2756:

1. Conservative defaults for Docker Desktop, OrbStack, Linux Docker, and CI.
2. Degraded-mode behavior for missing, stale, low-confidence, or slow Docker metrics.
3. Capacity-blocked user/operator messaging.
4. Shared, managed, and remote Docker backends default to manual unless explicitly opted in.

## Validation

Test coverage should include:

- Docker snapshot parsing for Docker Desktop/OrbStack/Linux Docker outputs.
- Container classification into control-plane, agent, service, and other.
- Cached snapshot freshness and timeout behavior.
- Auto admission when capacity is available.
- Denial when Docker memory is exhausted.
- Admission uses active agents' committed/recommended memory, not just current observed RSS.
- Existing manual capacity behavior remains unchanged in manual mode.
- Project-level and create-PR/account admission checks use auto-aware effective limits or clearly enforced hard ceilings.
- OOM-killed container detection.
- Profile updates from successful and OOM-killed runs.
- Recommended memory limit increases after OOM evidence.
- No aggressive downward memory-limit tuning.
- Queue processor leaves capacity-blocked runs queued and continues safely.
- UI displays effective capacity and degraded auto mode.

Operational validation should include:

- Running multiple agent runs until auto admission saturates Docker memory.
- Verifying Rails/Postgres/Temporal remain responsive under saturation.
- Forcing an OOM-killed agent container and confirming the next recommendation changes.
- Running with unrelated Docker containers active and confirming their usage reduces available agent capacity.
- Running with Docker metrics unavailable and confirming conservative fallback behavior.
- Running with a slow or hung Docker API and confirming queue processing remains bounded.

## Consequences

### Positive

- Removes the need for local users to tune `max_concurrent_runs`.
- Uses Docker's configured capacity as the explicit resource boundary.
- Adapts to different projects, runners, and goals from observed behavior.
- Reduces OOM loops by raising memory limits or lowering concurrency.
- Protects the Paid control plane from agent-container saturation.
- Keeps enterprise/manual control available.

### Negative

- Adds a new capacity-management subsystem.
- Requires reliable Docker metrics and container classification.
- Learned estimates can be wrong for new workloads.
- OOM feedback is inherently reactive and must be dampened.
- Local behavior may differ from managed/server deployments.
- Docker daemon access is privileged and must be handled as an operational trust boundary.

### Follow-up Questions

- How should Paid classify containers from multiple Paid checkouts on the same Docker daemon?
- Should CPU participate in admission after memory-first tuning has enough operational history?
- What fairness/isolation policy would make auto mode safe for remote Docker backends and managed shared deployments?
- Should slow Docker metrics collection get deployment-specific tuning beyond the current conservative degraded fallback?
