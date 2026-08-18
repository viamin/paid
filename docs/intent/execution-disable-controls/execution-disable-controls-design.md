---
parent: PAID
prefix: EXEC-DISABLE
---

# Low-Level Design: Execution Disable Controls

> Companion to [`docs/high-level-design.md`](../../high-level-design.md). This
> segment defines the operator kill-switch controls introduced for RDR-061.

## Purpose

Paid needs an operator-controlled way to stop new execution immediately without
redeploying, while still distinguishing between:

- **emergency disable**: unsafe or broken execution must stop and active runs
  should be cancelled and cleaned up, and
- **capacity disable**: new starts should stop and active runs should be parked
  so they can re-enter the normal queue after the control is cleared.

The control must work at the scopes operators actually reason about:
global, account, project, runner, and backend.

## Data model

`ExecutionControl` stores one mutable row per scope target:

- `scope`: `global | account | project | runner | backend`
- target foreign key: exactly one of `account_id`, `project_id`, `runner_id`,
  `docker_host_id` depending on scope
- `enabled`: current disable state
- `mode`: `emergency | capacity`
- `reason`, `metadata`, `enabled_at`, `disabled_at`

This is a control-plane record, not a historical ledger. Audit history comes
from structured logs plus `AccountActivityEvent`.

## Resolution

There is no single shared read path — each enforcement point reads
`ExecutionControl` directly, scoped to what it needs, because the queue
dispatch loop runs per-pass over many candidate runs and a per-run resolver
call there would be an N+1 query:

- `ProcessRunQueueJob#execution_control_snapshot_for_queue` loads every
  enabled global/account/project/runner control once per queue pass into an
  in-memory snapshot, and `#queue_parking_execution_control_for` looks up the
  highest-priority global/account/project match for a given run from that
  snapshot.
- `AgentRuns::RunnerResolver#runner_runnable?` and `Runners::PreflightCheck`
  query runner-scoped controls directly.
- `DockerHost.placement_ready_for_agent_runs` (and `#placement_ready?`)
  exclude backend-scoped controls directly.

Across all of these, scope priority is global > account > project > runner >
backend, and emergency wins over capacity when multiple controls apply —
see `ExecutionControl#priority`.

## Enforcement

### Queue dispatch

`ProcessRunQueueJob` checks the resolver before runner preflight and workflow
claim. If a global/account/project control applies, the queued run is parked as
`paused` with an `external_metadata["execution_control"]` marker so no new
dispatch starts while the control is active.

### Runner selection and preflight

Runner-scoped controls are enforced in two places:

- `AgentRuns::RunnerResolver#runner_runnable?` excludes disabled runners from
  late binding.
- `Runners::PreflightCheck` returns `execution_disabled` for pinned runs whose
  selected runner has been disabled since enqueue time.

### Backend placement

Backend-scoped controls piggyback on Docker host eligibility:
`DockerHost#placement_ready?` returns false when a backend-scoped control is
active, so host selection never places new runs onto that backend.

## Active-run behavior

`ExecutionControls::RunImpact` applies the mode-specific action to already
active scoped runs when a control is enabled:

- **emergency**: mark the run `cancelled` synchronously, enqueue
  `AgentRunCancellationJob` for workflow/container cleanup, emit logs/audit
- **capacity**: park the run as `paused` with the control marker
  synchronously, then enqueue `ExecutionControlParkCleanupJob` with the
  workflow/container ids captured immediately beforehand (the park mutation
  nulls them on the row) to cancel the workflow and tear down the container

Both modes keep the toggling process fast and defer network teardown (Temporal
cancel, Docker cleanup) to a background job with GoodJob retry semantics —
this matters most for a global capacity disable, which can walk every active
run system-wide.

When a capacity control is cleared, only runs parked by that exact control are
returned to `queued`. They do not start immediately; they re-enter the normal
queue and still pass capacity, policy, host, and runner checks.
