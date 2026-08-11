---
parent: PAID
prefix: RUNNER-SCHED
---

# Low-Level Design: Runner Time-Window Restrictions

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> covers per-runner time-based usage restrictions — configurable UTC-hour
> windows during which a runner is either blocked from selection or
> deprioritized, and the parking mechanism that holds a queued run until the
> earliest window opens when no alternative runner is available.

## Purpose

Some LLM providers adopt peak/off-peak pricing (e.g. DeepSeek's announced
2x peak-hour rates during UTC 1:00–4:00 and 6:00–10:00). Users who want to
avoid peak-hour costs need a way to tell Paid "don't use this runner during
those hours" — or "prefer not to, but fall back if nothing else is available."

This is a **cost-optimization guardrail**, not a safety control. It sits
alongside the existing cost budgets, token limits, and circuit breakers as
another data-driven selection filter.

## Data model

A JSONB column `time_restrictions` on the `runners` table, nullable (null =
no restrictions, the default). Shape:

```json
{
  "mode": "block",
  "timezone": "UTC",
  "windows": [
    { "start_hour": 1, "end_hour": 4 },
    { "start_hour": 6, "end_hour": 10 }
  ]
}
```

- **`mode`**: `"block"` (runner excluded from selection during windows) or
  `"deprioritize"` (runner sorted last; used only if no alternative exists).
- **`timezone`**: IANA timezone string (e.g. `"UTC"`, `"Asia/Shanghai"`).
  Defaults to `"UTC"`. The configured hours are interpreted in this timezone,
  then compared against the current time. This lets a user in UTC+8 enter
  peak hours in their local terms while Paid stores and evaluates them
  deterministically.
- **`windows`**: Array of `{ start_hour, end_hour }` where hours are integers
  0–23. `end_hour` is **exclusive**: `{ 1, 4 }` restricts during hours 1, 2,
  3 — the runner is available again at hour 4. Windows may wrap past
  midnight: `{ 22, 2 }` restricts from 22:00 to 02:00.

This follows the existing JSONB-column-on-Runner pattern
(`complexity_thresholds`, `no_progress_thresholds`, `tier_models`).

## Enforcement

### Selection-time filtering

Two enforcement points, matching the existing runner-selection architecture:

1. **`AgentRuns::RunnerResolver#runner_runnable?`** — a runner in `"block"`
   mode whose current time falls inside a restricted window is treated as
   not runnable. The resolver skips it and falls through to alternatives,
   exactly as it does for non-container-executable or excluded runners.

2. **`RunAgentActivity#build_runner_order`** — runners in `"block"` mode are
   filtered out of the ordered fallback chain. Runners in `"deprioritize"`
   mode are sorted to the end of the chain so they are used only when no
   non-restricted runner is available.

Both checks delegate to `Runners::TimeWindowCheck`, which encapsulates the
timezone-aware window-matching logic so it is testable in isolation and
callable from any selection path with an injectable `now:` clock.

### All-runners-blocked parking

When every eligible runner for a run is blocked by time-window restrictions
(no alternative available), the run is **parked** until the earliest window
opens. This mirrors the existing `rate_limited` parking +
`StaleRunDetectorJob` recovery pattern:

- `AgentRuns::BindRunner` detects the all-blocked condition and returns a
  structured result indicating the earliest next-available time.
- `ProcessRunQueueJob` parks the run as `rate_limited` with
  `rate_limited_until` set to that earliest time, so `StaleRunDetectorJob`
  re-queues it automatically when the window opens.
- A log entry records the parking reason (`time_window_blocked`) and the
  calculated resume time for observability.

If the all-blocked condition does not hold (at least one runner is
available), the run dispatches normally — the blocked runner is simply
skipped.

## What this is not

- **Not a pricing engine.** The system does not adjust cost calculations or
  apply surcharge multipliers. It blocks or deprioritizes usage to avoid
  peak-hour cost entirely.
- **Not a global policy.** Restrictions are per-runner record. A user with
  multiple DeepSeek-backed runners configures each independently.
- **Not a hard safety control.** In `"deprioritize"` mode the runner may
  still be used when no alternative exists. The restriction is a preference,
  not a guarantee.

## Goal-based economical routing

Some goals only read an issue body and reason about it — they don't need
aggressive codebase exploration. `enhance_issue` and `analyze_issue` are
lightweight goals (`AgentRun::LIGHTWEIGHT_GOALS`). Routing them through the
same round-robin pool as `create_pr` causes intermittent failures when a
lightweight task lands on a heavy-exploration runner (e.g. `claude_code`)
that consumes 15–20× more tokens for the same task, degrading
instruction-following near the context ceiling.

**Lean runners** (`RunnerSupport::LEAN_RUNNER_KEYS`) are economical runners
suitable for these goals. They are ordered by preference (`opencode`,
`omp`, `codex`) and deliberately exclude heavy-exploration runners so those
stay reserved for `create_pr` / `create_feature`.

### Enforcement

`UserSetting#select_automated_runner_identifier` short-circuits the
round-robin / random pool for lightweight goals:

1. If an explicit per-goal runner is configured in
   `default_agent_runners_by_goal`, it wins — the user's explicit choice is
   always respected.
2. Otherwise, the first lean runner the owner has enabled (in
   `LEAN_RUNNER_KEYS` priority order) is chosen.
3. If the owner has no lean runner enabled, the goal-specific default runner
   is used so the run still binds a runner.

Heavy goals (`create_pr`, `create_feature`, `review`, etc.) are completely
unaffected and continue to use the configured selection mode.

This is a **default routing preference**, not a hard constraint: it never
prevents a run from binding a runner, and users can override it per-goal by
setting `default_agent_runners_by_goal`.
