# EARS Specs: Runner Time-Window Restrictions

> Testable claims for per-runner time-based usage restrictions. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r RUNNER-SCHED-001`).

## Configuration and validation

- [x] **RUNNER-SCHED-001** — The system SHALL store a nullable `time_restrictions`
  JSONB column on the `runners` table, where null means no restrictions (the
  default for all existing runners).
  *Code:* migration `add_time_restrictions_to_runners`, `Runner#time_restrictions`.

- [x] **RUNNER-SCHED-002** — The system SHALL validate that `time_restrictions`,
  when present, contains a `mode` of `"block"` or `"deprioritize"`, a `timezone`
  that resolves to a known IANA zone (defaulting to `"UTC"`), and a `windows`
  array where each entry has integer `start_hour` and `end_hour` in 0–23.
  *Code:* `Runner#time_restrictions_must_be_valid`.

- [x] **RUNNER-SCHED-003** — The system SHALL interpret `end_hour` as exclusive:
  a window `{ start_hour: 1, end_hour: 4 }` restricts the runner during hours
  1, 2, and 3, making it available again at hour 4 in the configured timezone.
  *Code:* `Runners::TimeWindowCheck`.

- [x] **RUNNER-SCHED-004** — The system SHALL support windows that wrap past
  midnight: `{ start_hour: 22, end_hour: 2 }` restricts from 22:00 through
  01:59 in the configured timezone.
  *Code:* `Runners::TimeWindowCheck`.

## Block-mode enforcement

- [x] **RUNNER-SCHED-005** — When a runner's `time_restrictions.mode` is
  `"block"` and the current time (converted to the runner's configured
  timezone) falls inside any configured window, the runner SHALL be excluded
  from selection by `AgentRuns::RunnerResolver` (auto-pick) and SHALL fail
  `Runners::PreflightCheck` so a run already pinned to it before dispatch is
  rerouted to a healthy alternative instead of starting during the window.
  *Code:* `AgentRuns::RunnerResolver#runner_runnable?`,
  `Runners::PreflightCheck`, `Runners::TimeWindowCheck.blocked_at?`.

- [x] **RUNNER-SCHED-006** — When a runner's `time_restrictions.mode` is
  `"block"` and the current time falls inside a window, the runner SHALL be
  filtered out of the ordered fallback chain in
  `RunAgentActivity#build_runner_order`.
  *Code:* `Activities::RunAgentActivity#build_runner_order`.

## Deprioritize-mode enforcement

- [x] **RUNNER-SCHED-007** — When a runner's `time_restrictions.mode` is
  `"deprioritize"` and the current time falls inside a window, the runner
  SHALL remain eligible for selection but SHALL be sorted after all
  non-restricted runners in the fallback chain, so it is used only when no
  alternative is available.
  *Code:* `Activities::RunAgentActivity#build_runner_order`.

## All-runners-blocked parking

- [x] **RUNNER-SCHED-008** — When all eligible runners for a queued run are
  blocked by time-window restrictions (block mode, current time inside a
  window) and no alternative runner is available, the system SHALL park the
  run with `rate_limited_until` set to the earliest time any blocked
  runner's window opens, so `StaleRunDetectorJob` re-queues it automatically.
  This SHALL apply both to runner-agnostic (auto-pick) runs that cannot be
  bound and to pinned runs whose every reroute alternative is blocked.
  *Code:* `Runners::TimeWindowPark`, `ProcessRunQueueJob#reroute_unavailable_runner`,
  `ProcessRunQueueJob#park_run_for_time_window`.

- [x] **RUNNER-SCHED-009** — When at least one eligible runner is available
  (not time-window-blocked), the system SHALL dispatch the run normally and
  SHALL NOT park it, even if other runners are blocked.
  *Code:* `AgentRuns::BindRunner`.

## Next-available calculation

- [x] **RUNNER-SCHED-010** — The system SHALL compute the next time a
  time-window-restricted runner becomes available (the start of the first
  non-restricted hour after the current time in the configured timezone),
  used for parking-duration calculation and user-facing display.
  *Code:* `Runners::TimeWindowCheck#next_available_at`.
