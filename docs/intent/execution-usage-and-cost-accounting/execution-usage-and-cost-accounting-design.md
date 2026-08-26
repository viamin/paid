---
parent: PAID
prefix: EXEC-USAGE
---

# Low-Level Design: Execution Usage and Cost Accounting

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and the
> per-runner/host cost decision documents referenced below. This segment covers
> the per-run infrastructure usage record that gives Paid an apples-to-apples
> cost view alongside its existing LLM token/billing totals.

## Purpose

Paid already tracks significant LLM token cost data (`TokenUsage`,
`TokenUsageTracker`) and time-series CPU/memory samples
(`ContainerMetric`). What is missing for provider comparison is a
*billing-relevant* execution summary per run:

- which runner/backend actually executed the run;
- how long the cloud resource existed (provisioned → terminated), separately
  from the agent's wall-clock execution;
- what the run asked the cloud for (CPU, memory, disk);
- how the run ended (completed / cancelled / timed out / failed / evicted);
- a stable identifier the cloud provider uses for cost reconciliation;
- an estimated cost Paid can compare across providers today, and replace
  with provider-reported cost tomorrow.

This segment adds the record, the cost estimator, and the queryable
"total variable cost" surface that combine with the existing LLM ledger.
It does **not** introduce customer billing — that work is the next phase —
and the new totals stay outside `CostBudget` so the existing LLM-only
budget enforcement is unaffected.

## New Model: `ExecutionUsage`

One row per run, captured at termination. Each row carries:

| Field | Purpose |
|---|---|
| `agent_run_id` | The run this summary describes (unique, cascade-delete). |
| `runner_backend` | Which runner executed it (e.g. `local`, `fly_machine`, `cloud_run`). Mirrors the per-runner rate key. |
| `provider_resource_id` | Cloud-side identifier for cost reconciliation (Fly Machine ID, Cloud Run execution ID, etc). |
| `provisioned_at` / `execution_started_at` / `completed_at` / `terminated_at` | Lifecycle timestamps so billed duration can be derived precisely. |
| `billed_duration_seconds` | Provider-billed runtime — cloud providers charge for the full machine lifetime (provision → terminate), which is longer than agent wall-clock. |
| `requested_cpu_cores`, `requested_memory_mib`, `requested_disk_gb` | What the run requested from the cloud, so future size-aware pricing is possible. |
| `termination_reason` | `completed` / `cancelled` / `timed_out` / `failed` / `evicted`. |
| `infra_cost_cents` | Estimated (today) or provider-reported (later) infra cost. |
| `rate_cents_per_hour` | The rate the estimate used, snapshotted for reproducibility. |

`ContainerMetric` continues to carry the high-frequency CPU/memory samples
untouched — that stream is per-sampled observation, the new record is the
billing-relevant summary. They are deliberately separate tables so the
summary stays queryable without scanning the time-series.

## Cost Estimation

`ExecutionUsage::CostEstimator` is the only component that mints an
`infra_cost_cents` value today. Given:

- `billed_duration_seconds` (or a `(provisioned_at, terminated_at)` pair it
  derives from),
- `runner_backend` (the rate key), and
- a per-runner hourly rate resolved from
  `Capacity::InfrastructureLimits.rate_cents_per_hour(host:)`

it returns the estimated cost. The estimator is deterministic and pure —
no database writes, no telemetry — so it can be backfilled across existing
runs in a migration without re-running the admission path.

The estimator deliberately snapshots `rate_cents_per_hour` onto the
`ExecutionUsage` row. That keeps historical accounting fixed once computed:
later env-var rate changes do not retroactively re-price old runs, which
the existing `Capacity::InfrastructureSpend` already enforces for its
external-metadata stamp. Same invariant, different record.

## `AgentRun` Aggregate Fields

For dashboards that want one row per run without joining, `AgentRun`
gains:

- `runner_backend` — which backend actually executed it (string, ≤64 chars,
  nullable for runs that never reached provisioning).
- `infra_cost_cents` — the same value as `ExecutionUsage#infra_cost_cents`
  denormalized onto the run for cheap aggregation.

Existing `cost_cents` keeps its semantics as LLM cost. `total_cost_cents`
(`llm_cost_cents + infra_cost_cents`) becomes queryable per run, per
project, and per account via `AgentRun.total_cost_cents`.

## Dashboard Surface

`Projects::CostDashboardStats` already exposes `infrastructure_cost_cents`
alongside `total_cost_cents` (LLM). Once `ExecutionUsage` rows exist, the
dashboard switches its infra total to `SUM(execution_usages.infra_cost_cents)`
so the query matches the new table and not the external-metadata stamp.
The shape of the API is unchanged — the only difference is that `infra_cost_cents`
now reflects the per-run summary rather than the admission-time stamp,
and a run with no `ExecutionUsage` row contributes `0` instead of
contributing from the live rate.

## Why Not Fold This Into `ContainerMetric`?

`ContainerMetric` is append-only time-series data — one row per sample.
Adding `infra_cost_cents` to it would:

- conflate per-sample observation with billing summary;
- force every existing scan (anomaly detection, dashboards) to opt out of
  the billing columns;
- prevent the one-row-per-run aggregation from being indexed cheaply.

A separate table makes the "one summary per run" invariant enforceable by
a unique index on `agent_run_id` and keeps `ContainerMetric`'s query
planner from changing.

## Non-Goals

- Customer-facing billing (measurement only — keeps the existing LLM
  `BillingInvoice` flow untouched).
- Real-time cost ingestion from cloud provider APIs. The estimator runs
  first; provider-reported cost replaces it when available, swapping the
  same column.
- Cost optimization. We measure; we do not yet steer.
- Backfill beyond estimating historical runs. Existing runs with a stamped
  rate in `external_metadata["infrastructure_spend"]` get an
  `ExecutionUsage` row from a one-time backfill so dashboards agree with
  the threshold path during the transition.

## Dependencies

- #3354 (Provider-neutral execution resource requirements) — the requested
  resources fields on the new record come from `Capacity::RequestedResources`.
- #3338 (Runner abstraction) — `ExecutionResult` already carries the
  fields the new model needs; the wiring lands in the same release.