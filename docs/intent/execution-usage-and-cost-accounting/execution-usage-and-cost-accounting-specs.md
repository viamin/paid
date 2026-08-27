---
parent: PAID
prefix: EXEC-USAGE
---

# EARS Specs: Execution Usage and Cost Accounting

> Testable claims for the per-run infrastructure usage/cost record and the
> estimator that powers it. Status markers: `[x]` implemented · `[ ]` active
> gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r EXEC-USAGE-001`).

## Per-Run Usage Record

- [x] **EXEC-USAGE-001** — The system SHALL store a single `ExecutionUsage`
  row per `AgentRun` capturing `runner_backend`, `provider_resource_id`,
  `provisioned_at`, `execution_started_at`, `completed_at`, `terminated_at`,
  `billed_duration_seconds`, `requested_cpu_cores`, `requested_memory_mib`,
  `requested_disk_gb`, `termination_reason`, `infra_cost_cents`, and the
  snapshotted `rate_cents_per_hour` used to estimate it.
  *Tests:* `spec/models/execution_usage_spec.rb`,
  `spec/services/execution_usage_cost_estimator_spec.rb`.
  *Code:* `ExecutionUsage`,
  `ExecutionUsageCostEstimator`.

- [x] **EXEC-USAGE-002** — `AgentRun` SHALL denormalize `runner_backend` and
  `infra_cost_cents` from `ExecutionUsage` so a single-row aggregate query
  does not require a join against the usage record.
  *Tests:* `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRun`,
  `AgentRun#total_cost_cents`,
  `AgentRuns::RecordExecutionUsage`.

- [x] **EXEC-USAGE-003** — When `ContainerMetric` samples exist for a run,
  they SHALL NOT also contribute to `infra_cost_cents`; the cost summary
  is sourced exclusively from `ExecutionUsage`. High-frequency sampling
  and billing summaries are stored separately on purpose.
  *Tests:* `spec/services/projects/cost_dashboard_stats_spec.rb`.
  *Code:* `Projects::CostDashboardStats`,
  `Capacity::InfrastructureSpend`.

## Cost Estimator

- [x] **EXEC-USAGE-004** — `ExecutionUsageCostEstimator` SHALL compute
  estimated infra cost as `billed_duration_seconds / 3600 *
  rate_cents_per_hour`, rounded to the nearest cent, using a caller-supplied
  stamped `rate_cents_per_hour` when present and otherwise resolving the rate
  from `Capacity::InfrastructureLimits.rate_cents_per_hour(host:)` keyed by
  the record's `runner_backend`. A run with no stamped or resolvable rate
  SHALL contribute `0` cost and SHALL NOT raise.
  *Tests:* `spec/services/execution_usage_cost_estimator_spec.rb`.
  *Code:* `ExecutionUsageCostEstimator`,
  `Capacity::InfrastructureLimits`.

- [x] **EXEC-USAGE-005** — The estimator SHALL snapshot the resolved
  `rate_cents_per_hour` onto the `ExecutionUsage` row it returns so later
  rate-config changes do not retroactively re-price historical runs.
  *Tests:* `spec/services/execution_usage_cost_estimator_spec.rb`.
  *Code:* `ExecutionUsageCostEstimator`.

## Total Cost Queries

- [x] **EXEC-USAGE-006** — `AgentRun#total_cost_cents` SHALL return
  `cost_cents + infra_cost_cents`, giving a per-run total variable cost
  without requiring a join or scan of `execution_usages`.
  *Tests:* `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRun`.

- [x] **EXEC-USAGE-007** — `Projects::CostDashboardStats#summary` SHALL
  expose `total_variable_cost_cents` as the sum of LLM cost
  (`project.total_cost_cents`) and infra cost, using `ExecutionUsage`
  rows for terminated resources and overlap-based stamped-rate accounting
  for still-live or not-yet-cleaned runs, with no double-counting across
  the two sources.
  *Tests:* `spec/services/projects/cost_dashboard_stats_spec.rb`.
  *Code:* `Projects::CostDashboardStats`.

## Budget Isolation

- [x] **EXEC-USAGE-008** — Adding `ExecutionUsage` and `infra_cost_cents`
  SHALL NOT cause `CostBudget` to include infra cost in its enforcement
  totals. The existing LLM-only enforcement (`current_usage_cents`,
  `agent_run.cost_cents`) is unchanged.
  *Tests:* `spec/models/cost_budget_spec.rb`,
  `spec/services/cost_budgets/check_spec.rb`.
  *Code:* `CostBudget`,
  `CostBudgets::Check`.

## Recording and Historical Backfill

- [x] **EXEC-USAGE-009** — `AgentRun#cleanup_container` SHALL call
  `AgentRuns::RecordExecutionUsage` once the run's cloud resource is
  confirmed torn down (for any run that reached provisioning and recorded a
  backend host), and fallback cleanup paths SHALL reuse the same recorder,
  so `ExecutionUsage` rows are created by the real termination path even
  when the normal cleanup attempt fails and a later janitor/stale cleanup
  tears the resource down.
  *Tests:* `spec/models/agent_run_spec.rb`,
  `spec/jobs/agent_run_resource_janitor_job_spec.rb`,
  `spec/services/agent_runs/cleanup_stale_spec.rb`.
  *Code:* `AgentRun#cleanup_container`,
  `AgentRun#record_execution_usage_after_cleanup!`,
  `AgentRunResourceJanitorJob`,
  `AgentRuns::CleanupStale`.

- [x] **EXEC-USAGE-010** — A one-time migration SHALL backfill
  `ExecutionUsage` rows for historical `AgentRun`s that have a stamped
  `external_metadata["infrastructure_spend"]["rate_cents_per_hour"]` and a
  `completed_at`, using that stamped rate rather than a re-resolved
  current-env rate, so `Projects::CostDashboardStats`'s infrastructure
  totals do not silently drop to zero for runs that predate `ExecutionUsage`.
  The backfill SHALL skip runs whose environment may still be live —
  currently retained containers (unexpired `container_retained_until`) and
  runs with an environment `ExecutionResource` in the `active` or
  `cleanup_pending` state — so those runs keep accruing via the rowless
  overlap path (EXEC-USAGE-007) until real cleanup records their actual
  termination, instead of being frozen at `completed_at`.
  *Tests:* `spec/migrations/backfill_execution_usage_from_infrastructure_spend_stamp_spec.rb`.
  *Code:* `BackfillExecutionUsageFromInfrastructureSpendStamp`.

- [x] **EXEC-USAGE-011** — When an `ExecutionUsage` row already exists for a
  run and the current `provisioned_at` is on or before that row's
  `terminated_at`, `AgentRuns::RecordExecutionUsage` SHALL preserve the first
  recorded termination — `terminated_at` and the `billed_duration_seconds`,
  `infra_cost_cents`, and `rate_cents_per_hour` derived from it — instead of
  re-pricing the row against a later timestamp, and SHALL mirror the
  persisted row (never a freshly computed estimate) onto the run's
  denormalized columns. When the current `provisioned_at` is after the
  existing row's `terminated_at`, the recorder SHALL replace that row as a
  new billing cycle so park/resume and stale requeue re-provisioning record
  the later execution rather than freezing the old `evicted` termination.
  *Tests:* `spec/services/agent_runs/record_execution_usage_spec.rb`,
  `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRuns::RecordExecutionUsage`.
