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
  `spec/services/execution_usage/cost_estimator_spec.rb`.
  *Code:* `ExecutionUsage`,
  `ExecutionUsage::CostEstimator`.

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

- [x] **EXEC-USAGE-004** — `ExecutionUsage::CostEstimator` SHALL compute
  estimated infra cost as `billed_duration_seconds / 3600 *
  rate_cents_per_hour`, rounded to the nearest cent, where `rate_cents_per_hour`
  is resolved from `Capacity::InfrastructureLimits.rate_cents_per_hour(host:)`
  keyed by the record's `runner_backend`. A run with no resolvable rate
  SHALL contribute `0` cost and SHALL NOT raise.
  *Tests:* `spec/services/execution_usage/cost_estimator_spec.rb`.
  *Code:* `ExecutionUsage::CostEstimator`,
  `Capacity::InfrastructureLimits`.

- [x] **EXEC-USAGE-005** — The estimator SHALL snapshot the resolved
  `rate_cents_per_hour` onto the `ExecutionUsage` row it returns so later
  rate-config changes do not retroactively re-price historical runs.
  *Tests:* `spec/services/execution_usage/cost_estimator_spec.rb`.
  *Code:* `ExecutionUsage::CostEstimator`.

## Total Cost Queries

- [x] **EXEC-USAGE-006** — `AgentRun#total_cost_cents` SHALL return
  `cost_cents + infra_cost_cents`, giving a per-run total variable cost
  without requiring a join or scan of `execution_usages`.
  *Tests:* `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRun`.

- [x] **EXEC-USAGE-007** — `Projects::CostDashboardStats#summary` SHALL
  expose `total_variable_cost_cents` as the sum of LLM cost
  (`project.total_cost_cents`) and infra cost (from
  `execution_usages.infra_cost_cents`), with no double-counting across
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
  backend host), so `ExecutionUsage` rows are created by the real run
  termination path rather than only by test/backfill code.
  *Tests:* `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRun#cleanup_container`,
  `AgentRun#record_execution_usage!`.

- [x] **EXEC-USAGE-010** — A one-time migration SHALL backfill
  `ExecutionUsage` rows for historical `AgentRun`s that have a stamped
  `external_metadata["infrastructure_spend"]["rate_cents_per_hour"]` and a
  `completed_at`, using that stamped rate rather than a re-resolved
  current-env rate, so `Projects::CostDashboardStats`'s infrastructure
  totals do not silently drop to zero for runs that predate `ExecutionUsage`.
  *Tests:* `spec/migrations/backfill_execution_usage_from_infrastructure_spend_stamp_spec.rb`.
  *Code:* `BackfillExecutionUsageFromInfrastructureSpendStamp`.