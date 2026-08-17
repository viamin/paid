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

`ExecutionControls::Resolver` is the single read path used by dispatch code.
It evaluates the relevant active controls for a run and returns the highest
priority match:

1. global
2. account
3. project
4. runner
5. backend

Emergency wins over capacity when multiple controls apply.

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

- **emergency**: mark the run `cancelled`, enqueue cleanup, emit logs/audit
- **capacity**: cancel workflow/container without a terminal status, then park
  the run as `paused` with the control marker

When a capacity control is cleared, only runs parked by that exact control are
returned to `queued`. They do not start immediately; they re-enter the normal
queue and still pass capacity, policy, host, and runner checks.
