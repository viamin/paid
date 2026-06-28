# RDR-033: Worker Pool Scaling Algorithm

**Status**: Implemented
**Date**: 2026-04-17
**Issue**: #726

> Originally numbered RDR-024. Renumbered to RDR-033 to resolve collision with RDR-024 (Multi-Tenancy Isolation Strategy).

## Implementation Status

Implemented for the advisory algorithm and simulator. Paid has `Scaling::WorkerPoolAdvisor`, `Scaling::Configuration`, `Scaling::MetricsSnapshot`, and `Scaling::Simulator`; wiring advisor recommendations into live infrastructure autoscaling remains outside this RDR's pure-function scope unless a separate operational rollout is planned.

## Context

Paid's worker pools (GoodJob threads, Temporal activity slots, Docker containers) are currently statically sized. As workload grows and varies throughout the day, fixed pools either waste resources during quiet periods or bottleneck during bursts. We need an algorithm that recommends when to add or remove workers based on observable metrics, while respecting cost constraints and avoiding thrashing.

## Decision

Implement a hybrid reactive/predictive scaling algorithm as a pure-function service (`Scaling::WorkerPoolAdvisor`) that can be tested independently of actual infrastructure scaling.

### Algorithm Design

The advisor evaluates metrics in three layers:

#### Layer 1: Reactive Scaling

Compares current metrics against configured thresholds:

| Signal | Scale Up When | Scale Down When |
|--------|--------------|-----------------|
| Queue ratio (jobs/worker) | `> scale_up_queue_ratio` (default: 5.0) | `< scale_down_queue_ratio` (default: 0.5) |
| Utilization (busy/active) | `> scale_up_utilization` (default: 0.85) | `< scale_down_utilization` (default: 0.30) |

- **Scale up** triggers when *either* signal exceeds its threshold (OR logic — respond to the first sign of pressure).
- **Scale down** triggers only when *both* signals are below their thresholds (AND logic — avoid premature scale-down).

#### Layer 2: Predictive Pre-scaling

When a history of recent snapshots is available, the advisor detects a monotonically rising queue depth trend. If projecting the trend forward would breach the scale-up threshold, it pre-scales *before* the reactive layer fires. This reduces latency spikes during ramp-ups.

Requires at least 3 historical snapshots with consistently increasing queue depths.

#### Layer 3: Constraint Enforcement

After computing a raw decision, constraints are applied in order:

1. **Min/max bounds** — Target is clamped to `[min_workers, max_workers]`.
2. **Cost cap** — If `cost_per_worker_hour_cents` and `max_hourly_cost_cents` are set, the target is capped to `max_hourly_cost_cents / cost_per_worker_hour_cents`.
3. **Cooldown** — If `last_scaled_at` is within `cooldown_period` seconds, the decision is forced to `:hold`.
4. **Neutralization** — If constraints reduce the target back to the current count, the action becomes `:hold` with an explanatory reason.

### Configurable Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `min_workers` | 1 | Floor for worker count |
| `max_workers` | 10 | Ceiling for worker count |
| `scale_up_queue_ratio` | 5.0 | Queue depth per worker to trigger scale-up |
| `scale_down_queue_ratio` | 0.5 | Queue depth per worker below which scale-down is considered |
| `scale_up_utilization` | 0.85 | Busy fraction to trigger scale-up |
| `scale_down_utilization` | 0.30 | Busy fraction below which scale-down is considered |
| `cooldown_period` | 120s | Minimum seconds between scaling actions |
| `cost_per_worker_hour_cents` | 0 | Cost per worker per hour (0 = no cost tracking) |
| `max_hourly_cost_cents` | 0 | Maximum hourly spend (0 = unlimited) |
| `scale_up_step` | 1 | Workers to add per scale-up |
| `scale_down_step` | 1 | Workers to remove per scale-down |

### Tuning Guide

**Aggressive scaling** (latency-sensitive workloads):

- Lower `scale_up_queue_ratio` (e.g., 2.0)
- Lower `cooldown_period` (e.g., 30s)
- Increase `scale_up_step` (e.g., 3)

**Conservative scaling** (cost-sensitive workloads):

- Higher `scale_up_queue_ratio` (e.g., 10.0)
- Higher `cooldown_period` (e.g., 300s)
- Set cost caps via `max_hourly_cost_cents`

**Burst handling**:

- Use `scale_up_step: 2` or higher to add multiple workers at once
- Keep `cooldown_period` moderate (60–120s) to allow rapid follow-up scaling
- Enable predictive layer by passing snapshot history

### Components

| File | Purpose |
|------|---------|
| `app/services/scaling/configuration.rb` | Immutable config value object with validation |
| `app/services/scaling/metrics_snapshot.rb` | Point-in-time metrics input (queue depth, workers, utilization) |
| `app/services/scaling/worker_pool_advisor.rb` | Core algorithm — pure function returning a Decision struct |
| `app/services/scaling/simulator.rb` | Replays snapshot sequences to back-test configurations |

### Simulator

`Scaling::Simulator` replays historical or synthetic workload data through the advisor, tracking:

- Scale-up/down/hold counts
- Peak and minimum worker counts
- Estimated cost (worker-hours × cost per worker)
- Maximum queue depth observed

This enables offline tuning: try different configurations against the same workload to find the best cost/latency tradeoff.

## Consequences

- **Testable in isolation** — No database, no Docker, no Temporal dependency. The algorithm is a pure function of metrics and config.
- **Infrastructure-agnostic** — The advisor outputs decisions; the caller is responsible for executing them (adding containers, adjusting thread pools, etc.).
- **Incrementally adoptable** — Can start as a monitoring/recommendation tool before wiring to actual scaling actions.
- **Cost-aware** — Budget constraints are first-class, preventing runaway scaling.

## Alternatives Considered

1. **Purely reactive (no prediction)** — Simpler but adds latency during ramp-ups. The predictive layer is optional and lightweight.
2. **Machine learning–based** — More accurate long-term but requires training data and infrastructure we don't have yet. The trend detection heuristic is a practical starting point.
3. **Cloud provider auto-scaling** — Ties us to a specific provider. The algorithm layer is provider-neutral; cloud auto-scaling can be an execution backend.
