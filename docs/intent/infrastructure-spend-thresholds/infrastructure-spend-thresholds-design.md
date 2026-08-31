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

Historical accounting must stay fixed once computed. A run only contributes
spend using the rate stamped into its own
`external_metadata["infrastructure_spend"]["rate_cents_per_hour"]` at
admission time — `Capacity::InfrastructureSpend` never falls back to the
*current* `Capacity::InfrastructureLimits` config for a run that lacks a
stamped rate (e.g. a run in flight when this feature deployed). Repricing
from live config would make dashboards and threshold checks drift as the
host-rate env var changes, rather than reflecting what was actually true when
the run executed. An un-stamped run is treated as uncosted (contributes `0`)
and logged as `capacity.infrastructure_spend_rate_missing`, not guessed.

## Threshold Model

Threshold values come from `Capacity::InfrastructureLimits` and are optional
(`0`/unset disables the check; they are not part of the boot-required
production set — see `docs/PRODUCTION_CONFIG.md`):

- global hourly / daily thresholds — `MAX_GLOBAL_INFRA_SPEND_HOURLY_CENTS`,
  `MAX_GLOBAL_INFRA_SPEND_DAILY_CENTS`
- account hourly / daily thresholds — `MAX_ACCOUNT_INFRA_SPEND_HOURLY_CENTS`,
  `MAX_ACCOUNT_INFRA_SPEND_DAILY_CENTS`
- project hourly / daily thresholds — `MAX_PROJECT_INFRA_SPEND_HOURLY_CENTS`,
  `MAX_PROJECT_INFRA_SPEND_DAILY_CENTS`
- runner hourly / daily thresholds — `MAX_RUNNER_INFRA_SPEND_HOURLY_CENTS`,
  `MAX_RUNNER_INFRA_SPEND_DAILY_CENTS`

Host pricing comes from `INFRA_SPEND_RATE_CENTS_PER_HOUR` (optionally
overridden per host with a `__<HOST>` suffix), and the projection horizon from
`INFRA_SPEND_PROJECTION_SECONDS`. The guard uses:

- accrued spend in the relevant window for already-started runs, plus
- projected spend for the candidate run over the configured horizon, clipped to
  the remaining time in the window.

This is an estimate by design: it is good enough for admission safety without
pretending to be a billing engine.

Provider quotas, budgets, and billing alarms are **defense-in-depth
backstops**, not the enforcement model: Paid denies admission itself, before
provider provisioning starts, and provider-side controls only catch what slips
past Paid's own thresholds.

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

### Speculative Host Evaluation

Capacity-aware host selection (`ProcessRunQueueJob#build_host_admission_evaluations`)
evaluates admission once per *candidate* host before a winner is chosen. The
spend guard's side effects — notifications, audit events, and the automatic
global emergency control — must not fire for a candidate host that is
speculatively priced out but never actually used. `Capacity::RunAdmission` and
`Capacity::InfrastructureSpendGuard` each expose a `call`/`preview` method
pair: `preview` evaluates thresholds and returns the same decision shape as
`call` but records no side effects. Per-candidate evaluation always uses
`preview`; once the winning host is known,
`ProcessRunQueueJob#finalize_infrastructure_spend!` re-runs the real,
side-effecting `call` exactly once against only that host (skipped when the
preview never reached the spend guard, i.e. a non-spend capacity ceiling
already denied the run first).

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
