# EARS Specs: Worker Pool Scaling Advisor

> Testable claims for the advisory worker-pool scaling algorithm and its
> simulator (RDR-033). Scope is limited to advisory/simulator behavior;
> live autoscaling execution is out of scope. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r WORKER-POOL-SCALING-001`).

## Configuration

- [x] **WORKER-POOL-SCALING-001** — The system SHALL provide an immutable,
  validated scaling configuration value object exposing min/max worker
  bounds, queue-ratio and utilization thresholds, a cooldown period, worker
  step sizes, and optional cost caps, raising on unknown keys and invalid
  combinations (e.g. scale-down threshold not below scale-up threshold).
  *Code:* `Scaling::Configuration` (`DEFAULTS`, `validate!`).
  *Test:* `spec/services/scaling/configuration_spec.rb`.

## Metrics input

- [x] **WORKER-POOL-SCALING-002** — The system SHALL provide an immutable
  point-in-time metrics snapshot of queue depth and active/busy workers
  that derives `queue_ratio` (jobs per active worker; `Float::INFINITY` when
  jobs are queued with zero workers) and `utilization` (busy/active, 0.0
  with no workers), and SHALL reject negative counts or busy exceeding
  active.
  *Code:* `Scaling::MetricsSnapshot` (`queue_ratio`, `utilization`,
  `validate!`).
  *Test:* `spec/services/scaling/metrics_snapshot_spec.rb`.

## Reactive scaling

- [x] **WORKER-POOL-SCALING-003** — The advisor SHALL recommend `:scale_up`
  when queue ratio OR utilization exceeds its scale-up threshold, and
  `:scale_down` only when BOTH fall below their scale-down thresholds and
  the current count is above `min_workers`, otherwise `:hold`.
  *Code:* `Scaling::WorkerPoolAdvisor#scale_up_needed?`,
  `#scale_down_needed?`, `#compute_raw_decision`.
  *Test:* `spec/services/scaling/worker_pool_advisor_spec.rb`.

## Predictive pre-scaling

- [x] **WORKER-POOL-SCALING-004** — When at least three history snapshots
  show monotonically rising queue depth whose projection would breach the
  scale-up threshold, and the reactive layer does not already want
  scale-up, the advisor SHALL recommend `:scale_up` to pre-scale.
  *Code:* `Scaling::WorkerPoolAdvisor#trend_indicates_scale_up?`,
  `Scaling::WorkerPoolAdvisor::TREND_WINDOW_MIN`.
  *Test:* `spec/services/scaling/worker_pool_advisor_spec.rb`.

## Constraint enforcement

- [x] **WORKER-POOL-SCALING-005** — The advisor SHALL clamp its target to
  `[min_workers, max_workers]`, cap it by the configured cost limit when
  cost caps are set, convert a decision neutralized back to the current
  count to `:hold`, and force `:hold` when `last_scaled_at` is within the
  cooldown period, returning a reason explaining each outcome.
  *Code:* `Scaling::WorkerPoolAdvisor#apply_constraints`,
  `#in_cooldown?`, `#cooldown_decision`.
  *Test:* `spec/services/scaling/worker_pool_advisor_spec.rb`.

## Simulator

- [x] **WORKER-POOL-SCALING-006** — The system SHALL provide a simulator
  that replays a snapshot sequence through the advisor, threading the
  simulated worker count, rolling history, and cooldown between steps, and
  SHALL report scale-up/down/hold counts, peak and minimum worker counts,
  maximum observed queue depth, and an estimated total cost.
  *Code:* `Scaling::Simulator#call`, `Scaling::Simulator#compute_cost`,
  `Scaling::Simulator::Result`.
  *Test:* `spec/services/scaling/simulator_spec.rb`.

## Scope boundary (advisory only)

- [D] **WORKER-POOL-SCALING-007** — The advisor and simulator MAY later be
  wired into live infrastructure autoscaling (containers, thread pools,
  activity slots), but executing decisions against real pools is outside
  this segment's advisory/simulator scope until a separate autoscaling
  rollout is planned.
