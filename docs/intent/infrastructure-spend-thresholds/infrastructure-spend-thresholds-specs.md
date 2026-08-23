---
parent: PAID
prefix: INFRA-SPEND
---

# EARS Specs: Infrastructure Spend Thresholds

> Testable claims for RDR-061 infrastructure spend-threshold enforcement.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **INFRA-SPEND-001** — The system SHALL account infrastructure spend
  separately from LLM token/billing cost by deriving it from run
  provisioning/execution records and host-priced infrastructure rates, without
  incrementing `CostBudget` or `project.total_cost_cents`.
  *Tests:* `spec/services/capacity/infrastructure_spend_guard_spec.rb`,
  `spec/services/projects/cost_dashboard_stats_spec.rb`
  *Code:* `Capacity::InfrastructureSpend`,
  `ProcessRunQueueJob#start_claimed_run`,
  `Projects::CostDashboardStats`

- [x] **INFRA-SPEND-002** — When a global, account, or project hourly/daily
  infrastructure spend threshold would be exceeded by admitting a new run, the
  system SHALL deny admission before provisioning starts and SHALL park the
  queued run until the affected spend window resets.
  *Tests:* `spec/services/capacity/run_admission_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`
  *Code:* `Capacity::RunAdmission`,
  `ProcessRunQueueJob`

- [x] **INFRA-SPEND-003** — When a runner hourly/daily infrastructure spend
  threshold would be exceeded, the system SHALL fail that runner fast on the
  queue path and SHALL reroute to another healthy runner when available rather
  than provisioning on the over-limit runner.
  *Tests:* `spec/jobs/process_run_queue_job_spec.rb`
  *Code:* `Capacity::InfrastructureSpendGuard`,
  `ProcessRunQueueJob`

- [x] **INFRA-SPEND-004** — When the global daily infrastructure spend
  threshold is exceeded, the system SHALL escalate to an automatic global
  emergency execution disable and SHALL clear that automatic control once the
  daily window recovers.
  *Tests:* `spec/services/capacity/infrastructure_spend_guard_spec.rb`
  *Code:* `Capacity::InfrastructureSpendGuard`, `ExecutionControl`

- [x] **INFRA-SPEND-005** — The first threshold breach and the corresponding
  recovery SHALL emit a structured execution audit event and operator-visible
  logging, and account/project/runner breaches SHALL also publish or resolve an
  operator notification for the affected scope.
  *Tests:* `spec/services/capacity/infrastructure_spend_guard_spec.rb`
  *Code:* `Capacity::InfrastructureSpendGuard`, `ExecutionAuditEvent`,
  `Notifications::Publish`, `Notifications::Resolve`
