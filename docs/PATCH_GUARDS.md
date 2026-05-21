# Temporal Patch Guard Policy

`Temporalio::Workflow.patched(...)` is a temporary compatibility tool, not a permanent control flow primitive.

## Required Metadata

Every live patch guard in `app/temporal/workflows/` must have an entry in [`config/temporal_patch_guards.yml`](../config/temporal_patch_guards.yml).

Each entry records:

- `workflow_type`: the workflow class whose history carries the guard
- `introduced_on`: the UTC calendar date when the guard first landed

The registry is CI-checked by `spec/services/temporal_patch_guards/registry_spec.rb`. A new guard without registry coverage should fail CI. If sunset coverage cannot land in the same PR, add a `TODO(#issue)` comment beside the guard and open a tracking issue before merging.

## Sunset Rule

A guard becomes removable when the oldest still-running execution for that workflow type started after the guard’s introduction date.

The automated sweep stores only a date, not a deployment timestamp, so it evaluates removal conservatively:

- `introduced_on` is treated as expiring at the next UTC midnight
- a guard is sweep-eligible when `oldest_running_start_time >= introduced_on + 1 day`
- if there are no running executions for that workflow type, all tracked guards for that workflow type are eligible

## Sweep Process

Use either:

- `bin/rails temporal:patch_guards:sweep`
- `TemporalPatchGuardSweepJob`, scheduled quarterly through GoodJob cron

The sweep queries Temporal visibility for the oldest running execution per tracked workflow type and logs any eligible guard names for cleanup.

## Initial Sweep

Issue #2150 removed the expired `AgentExecutionWorkflow` guards:

- `agent-execution-quality-gate-v1`
- `provision_mcp_servers_v1`
- `check_proxy_health_before_clone`
- `check_proxy_health_before_push`
- `request_review_resolve_reviewer_from_project`
- `resolve_review_threads_with_prompt_thread_ids`

Those removals were safe without a live Temporal query because `AgentExecutionWorkflow` is runtime-bounded by `max_execution_seconds <= 86_400`, so workflows started before those April-May 2026 introductions could not still be running on May 21, 2026.
