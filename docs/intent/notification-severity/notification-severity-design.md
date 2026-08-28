---
parent: PAID
prefix: NOTIFICATION-SEVERITY
---

# Low-Level Design: Notification Severity Taxonomy

> Companion to the high-level design (`docs/high-level-design.md`). First of a
> three-part chain establishing a written notification-severity taxonomy:
> this segment (classification + badge scope) → `blocking` column + inbox
> derivation (#BLOCKING) → runner-auth notification gap + PR blocking entries
> (#GAPS).

## Purpose

`Notification#severity` (`info`/`warning`/`error`) has been assigned ad hoc
by each of the ~18 publisher call sites since the column was added, with no
written rule for what each level means. Two consequences followed directly
from that gap:

- Non-actionable sources (`agent_run_anomaly`, `queue_monitor`) emit
  `warning`/`error` and badge the bell, training users to ignore the badge.
- At least one genuinely blocking condition (`pr_followup_limit_reached`) is
  classified `info` and never surfaces.

This segment defines the classification rule every publisher must apply, and
records how the current set of publishers maps onto it (Classification
Record, below). It intentionally does **not** introduce a `blocking` column
or change inbox derivation — that is `#BLOCKING`. It only fixes `severity`
values and what the bell badge counts.

## The two-test classification gate

Apply both tests, in order, to decide a notification's severity:

1. **Is work halted?** Something stopped making progress — an agent run
   paused/terminated, a PR stuck, a background process unable to continue.
   If no (things are still running, or nothing was "doing" anything — this is
   an event or a telemetry sample) → **Info**.
2. **If halted, can it self-resolve?** Self-resolution means a retry,
   escalation path, quota window, or automated recovery clears the condition
   without a human doing anything. If it self-resolves → **Error** (no inbox
   entry — `#BLOCKING` will formalize this distinction with a `blocking`
   column). If it cannot self-resolve → **Error**, and semantically
   *Blocking* (inbox-worthy once `#BLOCKING` lands).

If work is merely **degraded but continuing** (a soft signal short of halting
— rising failure counts, a PR waiting longer than usual, quota usage
approaching a threshold) → **Warning**.

### Could vs. must

The gate turns on necessity, not possibility. "The user *could* increase the
token budget to make these warnings go away" does not make the condition
blocking — the run is still progressing. "The PR *cannot* continue without a
human decision because it exhausted its retry budget" is blocking — nothing
the system does next will change the outcome.

### Summary

| Test result | Severity | Badges bell | Inbox (future `#BLOCKING`) |
|---|---|---|---|
| Event/telemetry, nothing halted | `info` | No | No |
| Degraded, work continues | `warning` | Yes | No |
| Halted, self-resolves (retry/quota window/escalation) | `error` | Yes | No |
| Halted, cannot self-resolve | `error` | Yes | Yes (once `#BLOCKING` lands) |

## Badge semantics

The bell badge counts unread notifications the user has not already
dismissed or had auto-resolved, restricted to `warning` and `error`
severities. The rule is defined once in the `Notification.badging` scope
(`app/models/notification.rb`) and consumed by both badge-count call sites,
so a full render and a Turbo-stream bell replacement can never disagree:

- `NotificationsHelper#unread_notification_count` — full page renders
- `Notifications::Broadcasting` — Turbo-stream `broadcast_replace_to`
  updates pushed after `Notifications::Publish` / `Notifications::Resolve`

```ruby
scope :badging, -> { active.unread.where(severity: %i[warning error]) }
```

`info` notifications remain fully visible and filterable on the notifications
index page (`app/views/notifications/index.html.erb` already exposes an
`info` filter option) — this segment changes what the *badge counts*, not
what the page *lists*.

The bell dropdown lists all active, unread notifications regardless of
severity (`NotificationsController#index` under `dropdown: "true"`), so the
"Mark all read" button's visibility cannot reuse the badge count — an
account with only unread `info` notifications would show dropdown items with
no way to bulk-clear them. `NotificationsHelper#unread_notifications?` (and
the `any_unread` local threaded through `Notifications::Broadcasting`) tracks
this separately from `unread_notification_count`, using `active.unread` with
no severity filter.

`index_notifications_on_badge` is `(account_id, nav_section, read_at)` —
severity is not a leading or trailing column, so adding a `severity IN (...)`
predicate does not change which index Postgres picks for the `account_id`
equality lookup; it filters the matched rows after the index scan. Bell-badge
queries scope to one account with a handful of unread rows at a time, so the
added filter is not performance-sensitive enough to justify widening the
index (revisit if `#BLOCKING`'s inbox derivation query needs it).

## Classification Record

Audit of every `Notification` publisher as of this segment, evaluated
against the two-test gate. "Action" is what this segment changes; sources
without an action are already correctly classified.

| Source | Trigger | Current | Gate result | Action |
|---|---|---|---|---|
| `agent_run_anomaly` | Statistical anomaly on a run's metrics | `warning`/`error` (critical→error) | Info — `guardrail_will_fire?` already routes the actionable case (critical anomaly on a *running* run) to `guardrail_anomaly` instead of this source; what reaches `Publish` here is always non-actionable telemetry about a run that is already finished or not at risk | **Reclassify → always `info`** |
| `queue_monitor` | Background queue depth over threshold | `warning`/`error` | Info — internal operational signal on `subject: account`; nothing user-facing to click, no run/PR is halted | **Reclassify → always `info`** |
| `zero_iteration_timeout` | Run timed out with 0 iterations, 0 input tokens, no `container_id` | `error` (static) | Warning — a platform-bug signal that routes to the exception-handler/issue-filing path automatically; the run itself is terminal but the *response* to the signal is automatic, not a user action | **Reclassify → `warning`** |
| `pr_followup_limit_reached` | PR hit `max_pr_followup_runs` with no successful follow-up | `info` (static) | Blocking (halted, no auto-recovery — the PR sits until a human intervenes) | Deferred — needs the `blocking`/inbox machinery from `#BLOCKING` to surface correctly; reclassifying severity alone without that lands a false-positive-free but easy-to-miss `error`. Out of scope here (see `#GAPS`) |
| `agent_run_pattern_detector` (`agent_run_patterns/notify.rb`) | Recurring failure pattern across runs | `error` if worst pattern is error else `warning` | Matches gate already (halted pattern vs. degraded trend) | None |
| `agent_run_pattern_detector` (`agent_run_patterns/apply_decision.rb`) | Self-heal remediation applied, notify-only | `warning` (static) | Matches — remediation already applied automatically, work continues | None (note: this call site hardcodes `warning` where the sibling call site computes it dynamically off pattern severity; harmless today since `apply_decision` only notifies on the notify-only path, but worth reconciling if a future pattern type needs the escalation) |
| `infra_spend_threshold_*` (8 variants) | Spend projection breaches a global/account/project/runner threshold | `error` for `emergency_disable`/`park` actions, `warning` for `fail_fast` | Matches — `emergency_disable`/`park` halt spend with no self-resolution short of the next window; `fail_fast` is a degraded posture, not a halt | None |
| `exception_handler` | Unhandled exception classified | `error` if `p1` else `warning` | Matches — p1 is a halted/urgent condition, other priorities are degraded signals | None |
| `guardrail_*` (6 variants: `loop_detected`, `time_limit`, `token_limit`, `cost_limit`, `token_budget`, `anomaly`) | Guardrail terminates or pauses a run | `error` (static) | Matches — every guardrail firing halts the run; whether it self-resolves (pause, resumable) vs. not (terminal) is exactly the `blocking` distinction `#BLOCKING` adds on top of this `error` | None |
| `health_check/*` (10 finding codes) | Project/user configuration drift finding | `error` or `warning` per finding code | Matches — findings that block agent runs from functioning (`no_agent_runners`, `missing_git_hub_credential`) are `error`; softer drift (`deprecated_model`, `missing_default_runner`) is `warning` | None |
| `issue_merge_subscription` | Subscribed issue/PR merged or closed | `info` (static) | Matches — pure event notification, nothing halted, nothing to act on | None (this is the "merge events" badge complaint from the issue — already `info`; it stopped badging once the badge query excludes `info`, no source-level change needed) |
| `quality_gate_breach` | Quality metrics breach configured thresholds | `error` for severe/multi breach, `warning` otherwise | Matches — severe breach halts the gate (blocks merges), lesser breach is a degrading trend | None |
| `quality_auto_resume_cooldown` | Auto-resume hit its cooldown cap | `error` (static) | Matches — halted, requires manual review to resume, no further automatic retry | None |
| `quality_recovery` | Automatic quality recovery failed | `error` (static) | Matches — halted, the automated recovery path itself failed | None |
| `scanner_wedged_on_pending_review` | PR scanner sees repeated unsatisfied pending-review triggers | `warning` (static) | Matches — degraded (stuck waiting), not yet a hard halt; can still clear when the review bot responds | None |
| `repeated_no_changes` | Issue's recent runs repeatedly produced no changes | `info` (static) | Matches — informational trend, no run is halted | None |
| `provider_quota_exhausted` / `runner_quota_exhausted` | Provider/runner rate-limited past a threshold duration | `warning` under 2h, `error` at/over 2h | Matches — rate limiting is a quota window (self-resolving), so `error` here means "halted, self-resolving," consistent with the gate; short rate limits are a degraded posture (`warning`) | None |
| `stalled_draft_pr` | Draft/restarted PR stuck past a failure-count threshold | `warning` under 10 failures, `error` at/over | Matches — escalating failure count models the halted-vs-degraded line directly | None |

## What this is not

- **Not a `blocking` column or inbox derivation.** Sources marked
  "Blocking" in the gate above still map to `error` today; the boolean that
  distinguishes self-resolving `error` from inbox-worthy `error` is
  `#BLOCKING`'s job.
- **Not a fix for `pr_followup_limit_reached`.** It stays `info` in this
  segment because reclassifying it to `error` without the inbox/blocking
  machinery from `#BLOCKING` would surface it as a plain badge item
  indistinguishable from self-resolving errors, defeating the point. Tracked
  under `#GAPS`.
- **Not a consolidation of near-duplicate rules.** `provider_quota_exhausted`
  and `runner_quota_exhausted` share identical threshold logic across an STI
  boundary (`Provider < Runner`); `agent_run_pattern_detector`'s two call
  sites compute severity differently. Both are pre-existing and out of scope
  here — flagged for a future cleanup, not part of this taxonomy change.
- **Not a change to the notifications index page.** `info` notifications stay
  listed and filterable there; only the bell badge count changes.
