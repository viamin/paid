---
parent: PAID
prefix: RUNNER-QUOTA
---

# Low-Level Design: Runner Quota Tracking and Quota-Aware Routing

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> covers proactive runner quota snapshots, their presentation on `/runners`,
> and the routing rule that prefers runners with fresh remaining quota before
> reactive rate-limit failures happen.

## Purpose

Paid already tracks reactive runner health (`RunnerState` rate limits and
circuit state) and internal token usage. This segment adds the proactive half:
store a runner-scoped quota snapshot, refresh it on a schedule, show it in the
runner UI, and let routing prefer a healthier fallback when the primary runner
is nearing exhaustion.

The implementation stays inside the current architecture:

- Subscription runners use existing auth surfaces (`RunnerCredential`,
  host-mounted login state, or runtime materializers) and call
  `agent_harness`'s `check_quota`.
- API-key direct-outbound runners continue to use Paid's existing monthly token
  budget as the actionable quota source.
- Snapshots are persisted on `RunnerState#metadata["quota_status"]`, keyed by
  the runner's `state_key`, rather than introducing a second runner-state table.

## Behavior

`Runners::RefreshQuotaSnapshots` is the scheduled writer. Every refresh
produces a new snapshot for each agent-enabled runner:

- Supported subscription runners persist the provider-reported remaining quota,
  limit, reset time, unit, and `checked_at` timestamp.
- API-key runners persist the remaining monthly token budget derived from
  `TokenUsage`.
- Unsupported, empty, stale, or failed provider checks overwrite any previous
  optimistic snapshot with an unavailable marker (`provider_unsupported`,
  `provider_no_data`, or `refresh_failed`) so quota-aware routing falls back to
  the existing reactive runner order immediately.

`RunnerState` is the canonical interpreter for stored snapshots. It computes
headroom only when the snapshot is both available and fresh. Snapshots older
than `QUOTA_STATUS_STALE_AFTER` are treated as stale and ignored by routing.

`RunAgentActivity#build_runner_order` applies quota-aware ordering after
issue-aware failure ordering and before time-window filtering:

- If the primary runner has fresh headroom below the low threshold and a
  fallback has fresh headroom above the preferred threshold, the fallback is
  promoted.
- If quota data is missing, unsupported, stale, or failed, runner ordering
  stays on the existing reactive path.

`/runners` shows the same state the scheduler uses:

- Fresh snapshots show remaining percentage, remaining/limit, unit, last check,
  and reset time.
- Unsupported or failed refreshes show explicit reactive-fallback messaging.
- Stale snapshots show that quota routing is paused until the next refresh.

## What this is not

- **Not a new quota-credential subsystem.** Managed runner credentials remain
  in the existing `RunnerCredential` architecture and host/runtime auth paths.
- **Not a hard block on unsupported providers.** Providers without a quota API
  stay runnable; they simply do not influence proactive quota routing.
- **Not a replacement for reactive health.** Rate limits and circuit state
  remain the fallback availability source whenever proactive quota is absent.
