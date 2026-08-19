---
parent: PAID
prefix: EXEC-DISABLE
---

# EARS Specs: Execution Disable Controls

> Testable claims for RDR-061 emergency execution disable controls.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **EXEC-DISABLE-001** — The system SHALL persist execution disable
  controls at global, account, project, runner, and backend scope without
  requiring a redeploy.
  *Code:* `ExecutionControl`, migration `create_execution_controls`.

- [x] **EXEC-DISABLE-002** — When a global, account, or project execution
  disable control applies to a queued run, the system SHALL stop new dispatch
  before workflow claim and SHALL park the run instead of starting execution.
  *Tests:* `spec/jobs/process_run_queue_job_spec.rb`
  *Code:* `ProcessRunQueueJob#execution_control_snapshot_for_queue`,
  `ProcessRunQueueJob#queue_parking_execution_control_for`.

- [x] **EXEC-DISABLE-003** — When a runner-scoped execution disable control
  applies, the system SHALL exclude that runner from late binding and SHALL
  fail pinned-run preflight with `execution_disabled`.
  *Tests:* `spec/services/runners/preflight_check_spec.rb`
  *Code:* `AgentRuns::RunnerResolver#runner_runnable?`,
  `Runners::PreflightCheck`.

- [x] **EXEC-DISABLE-004** — When a backend-scoped execution disable control
  applies, the system SHALL treat that backend as ineligible for new placement.
  *Code:* `DockerHost.placement_ready_for_agent_runs`.

- [x] **EXEC-DISABLE-005** — When an emergency execution disable control is
  enabled for a scope, the system SHALL cancel active scoped runs and enqueue
  cleanup for their workflow/container resources.
  *Tests:* `spec/models/execution_control_spec.rb`
  *Code:* `ExecutionControls::RunImpact`.

- [x] **EXEC-DISABLE-006** — When a capacity execution disable control is
  enabled for a scope, the system SHALL park active scoped runs and, when the
  control is cleared, SHALL return only those parked runs to `queued` so they
  re-enter normal capacity and policy checks rather than bypassing them.
  *Tests:* `spec/models/execution_control_spec.rb`
  *Code:* `ExecutionControls::RunImpact`, `ExecutionControlParkCleanupJob`.

- [x] **EXEC-DISABLE-007** — The system SHALL emit structured logs and account
  audit events for execution-control enable/disable transitions and for the
  affected runs it cancels or parks.
  *Code:* `ExecutionControls::RunImpact`, `AccountActivityEvent`.
