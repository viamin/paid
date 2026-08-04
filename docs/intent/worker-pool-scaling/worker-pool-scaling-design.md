---
parent: PAID
prefix: WORKER-POOL-SCALING
---

# Low-Level Design: Worker Pool Scaling Advisor

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the **advisory** worker-pool scaling algorithm and its
> simulator (RDR-033). Wiring advisor recommendations into live
> infrastructure autoscaling is explicitly out of scope for this segment —
> the advisor is a pure function; the caller is responsible for executing any
> decision it returns.

## Purpose

Paid's worker pools (GoodJob threads, Temporal activity slots, Docker
containers) are statically sized and either waste resources when quiet or
bottleneck under bursts. The advisor recommends when to add or remove
workers from observable metrics while respecting cost constraints and
avoiding thrashing — testable in isolation, with no database or Docker
dependency.

## Components

| File | Role |
|---|---|
| `Scaling::Configuration` | Immutable, validated config value object (thresholds, bounds, cooldown, cost caps) |
| `Scaling::MetricsSnapshot` | Point-in-time metrics input (queue depth, active/busy workers); derives `queue_ratio` and `utilization` |
| `Scaling::WorkerPoolAdvisor` | Core pure-function algorithm returning a `Decision` (`:scale_up` / `:scale_down` / `:hold`, target workers, reason) |
| `Scaling::Simulator` | Replays a snapshot sequence through the advisor, tracking counts, peak/min workers, cost, max queue depth for offline tuning |

All four are plain Ruby with no ActiveRecord dependencies, so the algorithm
is exercised without a database.

## Algorithm

The advisor evaluates a snapshot (plus optional history) in three layers:

1. **Reactive** — scale up when *either* queue ratio or utilization exceeds
   its scale-up threshold (OR — respond to first pressure); scale down only
   when *both* are below their scale-down thresholds (AND — avoid premature
   scale-down), and never below `min_workers`.
2. **Predictive** — with a history of at least three snapshots showing
   monotonically rising queue depth whose projection would breach the
   scale-up threshold, pre-scale before the reactive layer fires. Skipped
   when the reactive layer already wants scale-up.
3. **Constraints** (applied after the raw decision): clamp the target to
   `[min_workers, max_workers]`; if a cost cap is configured, cap the target
   to `max_hourly_cost_cents / cost_per_worker_hour_cents`; if a change is
   neutralized back to the current count, convert it to `:hold`; and if a
   `last_scaled_at` is within `cooldown_period`, force `:hold` regardless of
   the raw decision (cooldown is checked first).

The simulator rewrites each historical snapshot's `active_workers` to the
pool size that would actually exist, threads the advisor's decisions and a
rolling history through the sequence, and estimates cost from worker-hours
between snapshots — enabling back-testing different configurations against
the same workload.

## Scope boundary

This segment covers only the advisory algorithm and simulator. Any rollout
that consumes advisor output to actually resize live pools (containers,
thread pools, activity slots) belongs to a separate autoscaling-operations
segment/issue and is not claimed here.

## What this is not

- **Not live autoscaling.** The advisor returns decisions; it changes no
  infrastructure.
- **Not provider-specific.** The algorithm is provider-neutral; cloud
  auto-scaling can be one execution backend.
- **Not ML-based.** The trend heuristic is a deterministic, inspectable
  starting point; learned models are future work.
