---
parent: PAID
prefix: INFRA-SPEND
---

# Low-Level Design: Infrastructure Spend Thresholds

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [`docs/rdrs/RDR-061-infrastructure-safety-and-audit.md`](../../rdrs/RDR-061-infrastructure-safety-and-audit.md).
> This segment covers the pre-provisioning infrastructure-spend guardrails that
> land after infrastructure cost accounting exists.

## Purpose

Paid already enforces LLM token/cost budgets and infrastructure-capacity
ceilings, but those are different controls:

- LLM budgets protect customer billing and model spend.
- Capacity guardrails protect CPU/memory/disk headroom.
- Infrastructure spend thresholds protect operator cloud spend before new
  provisioning starts.

This segment adds a deterministic admission-time spend check that uses
infrastructure cost records for already-started runs plus a configured
projection for the candidate run. The result must stay separate from customer
billing and from `CostBudget`.

## Accounting Source

Infrastructure spend is accounted against the run lifecycle, not against
`TokenUsage`:

- Each admitted run records a host-priced infrastructure rate in
  `agent_runs.external_metadata["infrastructure_spend"]`.
- The accounting window starts at `provisioning_started_at`, because that is
  when Paid begins external provisioning work.
- Finished runs contribute spend through `completed_at`.
- Active runs contribute spend through `Time.current`.
- Paused / rate-limited runs with no terminal timestamp do not keep accruing
  spend after they leave active execution.

This remains intentionally separate from `agent_runs.cost_cents`,
`project.total_cost_cents`, and `CostBudget`, which continue to represent LLM
cost only.

## Threshold Model

Threshold values come from `Capacity::InfrastructureLimits` and are optional:

- global hourly / daily thresholds
- account hourly / daily thresholds
- project hourly / daily thresholds
- runner hourly / daily thresholds

Paid also records a configurable projection horizon for the candidate run. The
guard uses:

- accrued spend in the relevant window for already-started runs, plus
- projected spend for the candidate run over the configured horizon, clipped to
  the remaining time in the window.

This is an estimate by design: it is good enough for admission safety without
pretending to be a billing engine.

## Enforcement Behavior

The spend guard runs on the same pre-provisioning path as the existing
infrastructure safety rails:

- global/account/project hourly or daily breaches park queued runs until the
  next window boundary
- runner hourly or daily breaches fail that runner fast and let the queue
  reroute to another healthy runner when available
- a global daily breach escalates to an automatic global emergency
  `ExecutionControl`, because the whole deployment is beyond its daily spend
  envelope rather than just temporarily busy

Recovery is deterministic:

- parked runs already recover through `rate_limited_until` and
  `StaleRunDetectorJob`
- rerouted/fail-fast runner denials recover when the next queue pass sees the
  runner window back under threshold
- the auto-generated global emergency control clears itself once the global
  daily window is back under the threshold

## Audit and Operator Signals

Every first breach and recovery emits:

- an `ExecutionAuditEvent`
- a structured log entry
- an operator-visible `Notification` for account/project/runner scope when that
  scope has a concrete subject

Global daily escalation also reuses `ExecutionControl`'s existing
account-activity event trail when the automatic emergency control toggles.

## Dashboard Surface

Project cost dashboards can show total variable run cost by combining:

- existing LLM cost totals, and
- the separately-accounted infrastructure spend totals

This is a presentation join only. It does not merge the accounting ledgers or
feed infrastructure spend back into `CostBudget`.
