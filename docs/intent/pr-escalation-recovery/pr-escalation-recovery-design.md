---
parent: PAID
prefix: PR-ESCALATION
---

# Low-Level Design: PR Escalation Recovery

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers what happens after Paid stops working a pull request: what
> holds it stopped, how the owner sees it, and how it is cleared.
> `focused-agent-runs` owns the token fuse and the failure detection that
> *trigger* escalation; this segment owns everything downstream of the stop.

## Purpose

Paid escalates a PR when it can no longer make progress on its own — a failure
streak, a retry limit, a token cap, an infrastructure breaker. Escalation is a
handoff: the PR is now the owner's problem, and it stays stopped until the owner
acts.

A handoff nobody sees is a stall. The counters that stop a PR
(`draft_review_count`, `pr_followup_count`, `review_goal_retry_count`, tokens
spent against the project cap) live only in the database, so a stopped PR looks
identical to a PR that simply has nothing to do. This segment makes the stop
visible, gives it one deliberate clearing action, and keeps the paths that clear
it from drifting apart.

## What stops a PR

| Reason key | What trips it | Counter vs. limit |
|---|---|---|
| `failure_streak` | Draft review rounds or follow-up runs exhausted with the triggering condition unresolved | `draft_review_count` vs `max_draft_review_rounds`; `pr_followup_count` vs `max_pr_followup_runs` |
| `review_goal_retry_limit` | Review-goal runs keep failing | `review_goal_retry_count` vs the project's review-goal retry limit |
| `pr_auto_continue_token_limit` | Automatic runs on the PR have spent the project's token budget | tokens used vs `max_pr_auto_continue_tokens` |
| `operational_failures` | Provider/infrastructure failures burst *and* the PR went stale without meaningful progress | `consecutive_operational_failures`, `last_meaningful_progress_at` |
| `awaiting_approval` | A green PR, blocked only on owner approval, has waited past the project ceiling | `awaiting_approval_since` vs `pr_approval_escalation_hours` |

The first four reasons denote agent failure — Paid could not make progress.
`awaiting_approval` denotes an unanswered human gate: every
automatic-merge precondition except owner approval is satisfied and nobody
has answered it. It is the backstop, not the first response: the inbox entry
and the review re-request get a fair chance to work first, and past the
ceiling "nobody is coming" is itself the failure.

Escalation requires confirmation across `REQUIRED_STUCK_CONFIRMATIONS` scan
cycles (`stuck_confirmation_count`), so a single bad scan cannot stop a PR.
That confirmation gate applies to the failure detectors; the approval wait
carries its own time-based ceiling (`pr_approval_escalation_hours`, default
24 hours) because the stuck state it measures — an unanswered approval —
cannot be a scan artifact.

## The escalated phase is the hold

`pr_review_phase == "escalated"` is the whole of the hold. There is no
accompanying pause flag, because two fields encoding one state drift apart —
and a drifted hold is how a stopped PR becomes an invisible one.

Holding is enforced where the work is decided: while a PR is escalated, the scan
performs **recovery detection only**. It looks for the owner clearing the
escalation and for owner approval that unblocks auto-merge. It does not collect
CI, review-thread, merge-conflict, or conversation triggers, and it queues no
follow-up runs — on any path, including the skip-unchanged merge-conflict
rescan, which bypasses the escalated-phase branch entirely and so is gated
separately. A PR whose owner has
been asked to intervene does not keep getting worked while they think about it.

The operator's own per-PR pause (`auto_continue_paused`) is a different state
with a different owner. It excludes the PR from the scan entirely at the source
(`Issue.auto_continue_active`) — the owner asked Paid to leave the PR alone, so
Paid does not look at it. The system never sets it.

That asymmetry is the load-bearing rule: **the flag that removes a PR from the
scan must never be set by the system.** Every automatic recovery path — the
owner removing `paid-escalated`, converting the PR to draft, an operational
escalation clearing itself once failures recover — is *detected inside the
scan*. A system-set scan-exclusion flag deadlocks: the state that needs clearing
hides the code that would clear it, and the escalation comment's instructions
("remove the label", "convert to draft") silently become no-ops.

Escalation does not cancel automatic runs already queued for the PR. The hold
governs what work is *decided*, not what is already in flight; an in-flight run
finishes and reports, which is information the owner wants.

## Recovery paths

Three owner-initiated ways in, one outcome:

1. **Remove `paid-escalated` on GitHub.** The scan's escalated branch detects
   the missing label and clears the escalation.
2. **Convert the PR to draft on GitHub.** The scan restarts the PR into the
   `restarted` phase.
3. **Unblock from the dashboard.** Applies the same clearing immediately,
   without waiting for a scan cycle, and removes `paid-escalated` on GitHub so
   the PR does not re-sync as escalated.

All three converge on one clearing operation so they cannot drift apart.

Unblock does not enqueue a run. Deciding what a stopped PR needs next — a CI
fix, a review-thread pass, a rebase — is the scan's judgment, and guessing at it
from a button press produces the wrong run as often as the right one (a PR
stopped by a review-goal retry limit does not need a `create_pr`). Clearing the
hold returns the PR to the scan, which picks the work on the next cycle.

A fourth path clears the hold without an owner: an `operational_failures`
escalation whose failure signals have recovered dismisses itself.

For an `awaiting_approval` escalation the recovery path is the gate itself:
the owner approving the PR routes it to auto-merge on the next scan, which
merges it and clears the escalation — no label surgery. The escalation
comment therefore names re-approval as the remedy, not the agent-failure
steps ("remove the label", "convert to draft") that would be actively
misleading for a PR that already passed every other check.

## The approval-wait ceiling

The wait is measured from the scan's **first observation** that the PR is
blocked only on approval (`awaiting_approval_since`), not from PR creation —
a PR that was legitimately in review for a week has not been waiting on
approval for a week. Whenever any non-approval blocking signal appears (CI
failure, review feedback, a conflict, a stale approval, an unmerged
dependency), the stamp is cleared; if the PR later returns to
blocked-only-on-approval, the wait restarts from that observation.

The ceiling is per project (`pr_approval_escalation_hours`, default 24,
`0` disables). One day is long enough for the inbox entry and the review
re-request to work first. Because the escalated PR stays in the scan
(staleness ceiling applies to escalated PRs regardless of author), approval
is detected and the hold clears itself without manual intervention.

`awaiting_approval` deliberately inherits none of the behavior attached to
the agent-failure reasons: clearing it does not stamp the
`pr_auto_continue_token_limit` override, and its escalation carries no
failure-budget semantics — there were no failed attempts to reset.

## The clearing operation

Clearing an owner-initiated escalation clears everything the escalation counted:

- `pr_review_phase` → `restarted` when the PR is a draft, `ready` otherwise
- `pr_escalation_reason` → `nil`
- `paid-escalated` removed from the local labels array and from GitHub
- `draft_review_count`, `pr_followup_count`, `review_goal_retry_count`,
  `stuck_confirmation_count` → `0` — the confirmation count is what proved the
  PR stuck across scan cycles, so it cannot survive the owner's intervention
- `review_goal_retry_reset_at`, `operational_failure_reset_at` → now
- `ci_retry_requested_at` → `nil`
- for a `pr_auto_continue_token_limit` escalation,
  `pr_auto_continue_token_limit_overridden_at` → now

The counters measure *attempts since the owner last looked*, not attempts for
all time. Escalation is the moment the owner looks, so clearing it restarts the
count. A clearing that resets the phase but leaves the counters at their limit
re-escalates on the next scan, which reads to the owner as the unblock button
not working.

The token-limit override is deliberately different: it is a standing permission
to exceed the cap on that PR, not a counter, so it is stamped once and persists.

**Operational auto-dismissal releases the hold without zeroing the counters.**
Its justification — the owner has looked — is exactly what did not happen. An
infrastructure blip recovering is not a reason to hand the PR a fresh budget of
draft rounds.

The clearing operation governs escalation only. Converting a `ready` PR to draft
is a restart, not a recovery, and keeps its own narrower reset.

## Concurrency and boundaries

The clearing is applied under a row lock on the issue, so two owners clicking
Unblock at the same moment produce one clearing.

An Unblock on a PR that closed or merged between page render and click is
refused and the row refreshed, rather than resetting counters on a PR nobody
will work again.

Recovery detection must keep running for as long as a pull request is
escalated: the scan staleness ceiling applies to every escalated pull request
regardless of author, so one whose GitHub `updated_at` has stopped advancing is
still rescanned rather than skipped forever.

Removing the label from GitHub is best-effort — a GitHub failure must not leave
the local clearing half-applied. The PR is cleared locally and the failure
logged; the next sync reconciles the label, and a stale `paid-escalated` on a
non-escalated PR does not re-escalate anything.

Clearing an escalation is authorized as running an agent on the project: an
owner who can start a run can clear a hold on one.

## Retiring the escalation-set pause

Escalations that predate this design set `auto_continue_paused`, which is
indistinguishable from an operator pause by the column alone. `pr_review_phase`
disambiguates: the operator toggle never writes the phase, so an open pull
request sitting at `escalated` was stopped by the system. A one-time migration
releases the pause on exactly those rows, returning them to the scan; every
other paused pull request keeps the operator's hold untouched.

The migration establishes system tenant access explicitly. `issues` carries
forced row-level security, so a migration that relies on an ambient tenant
context matches zero rows and silently succeeds having changed nothing.

## Blocked-work surface

A dashboard panel lists every open PR in the account that Paid has stopped
working, so the state is visible without opening a project or reading the
database.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Blocked PRs (10)                                                         │
├───────────┬──────────────┬───────────────┬──────────┬──────────┬─────────┤
│ PR        │ Project      │ Why           │ Counter  │ Blocked  │         │
├───────────┼──────────────┼───────────────┼──────────┼──────────┼─────────┤
│ #3396     │ paid         │ Failure streak│ 18 / 10  │ 1d 2h    │[Unblock]│
│ #3486     │ paid         │ Token cap     │ 51M / 50M│ 1d 1h    │[Unblock]│
│ #24       │ ColorMatch…  │ Retry limit   │ 8 / 8    │ 1d 4h    │[Unblock]│
└───────────┴──────────────┴───────────────┴──────────┴──────────┴─────────┘
```

Rows are scoped to the current account, ordered longest-blocked first, and each
carries the reason in the project's own words, how long the PR has been stopped,
and a one-click **Unblock**.

A reason does not map to one counter. `failure_streak` is tripped by either the
draft-round counter or the follow-up counter, and `operational_failures` has no
counter of that shape at all. The panel therefore shows *every* counter that has
reached its limit, and for an operational escalation shows time since the PR
last made meaningful progress.

The panel reads issue state directly, like the other dashboard panels. It is a
*surface*, not a detector — no new blocked-state logic lives in the view layer.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|---|---|---|---|
| Representing the hold | The `escalated` review phase, and nothing else | A dedicated `escalation_paused` column; reuse the operator's `auto_continue_paused` | Reusing the operator's flag deadlocked recovery, because the scan filters on it. A dedicated column would be a second field encoding one state, free to drift from the phase — the same failure one layer over. The phase already names the state; the fix is to make it actually hold. |
| Enforcing the hold | Recovery-only scanning while escalated | Keep collecting work triggers and gate them downstream; pause the PR out of the scan | Gating downstream is what failed: the escalated branch collected CI, review, and conflict triggers and queued follow-ups against them. Excluding from the scan hides the recovery paths. Deciding no work while escalated puts the hold where the work is decided. |
| Which flag excludes a PR from the scan | Only `auto_continue_paused`, only ever set by the operator | Exclude on escalation too | Recovery is detected inside the scan, so anything the system sets must not hide the PR from it. The operator's pause is safe to exclude on because the operator also clears it. |
| Clearing semantics | Full reset of every escalation counter | Reset only the counter named by `pr_escalation_reason`; clear the phase and leave counters intact | The counters mean "attempts since the owner last looked". A partial reset lets a second cap re-trip immediately, which is indistinguishable from a broken button. |
| Operational auto-dismissal | Releases the hold, leaves counters | Apply the full reset like the owner-initiated paths | The full reset is justified by owner attention, which auto-dismissal does not involve. Recovering infrastructure should return the PR to work, not grant it a fresh failure budget. |
| Token-cap override on clearing | Stamp `pr_auto_continue_token_limit_overridden_at` | Zero the token usage; raise the project cap | Token spend is real and already incurred; it cannot be un-spent. The override is the owner granting one PR permission to exceed the cap, and it is scoped to that PR. |
| What Unblock enqueues | Nothing; the scan picks the work | Enqueue a `create_pr` follow-up immediately | What a stopped PR needs next is a semantic judgment the scan already makes from live PR state. A button that hardcodes `create_pr` queues the wrong run for a PR stopped on a review-goal retry limit. Costs one poll cycle. |
| Approval-wait origin | First scan observation of blocked-only-on-approval (`awaiting_approval_since`) | PR creation time; the last green CI run | The wait is a property of the approval gate, not of the PR. Creation time counts review time the owner was never asked to answer for; the gate can also open and close as other blockers appear, so the stamp resets when they do. |
| Approval-wait ceiling | Per-project hours (`pr_approval_escalation_hours`, default 24, 0 disables) | A fixed constant; scan-confirmation counts | How long an owner should take is a team property. The failure detectors need scan confirmations because their signal can be a scan artifact; an unanswered approval cannot be. |
| Queued runs at escalation | Left alone | Cancel them, as the operator pause does | The hold governs what work is decided next, not what is already running. A run in flight finishes and reports, which is information the owner wants before deciding. |
| Where blocked PRs surface | Dashboard panel querying issue state | A `Notifications::Rule`; a per-project page only | Notifications are event-shaped and dismissible; a stopped PR is a standing condition that should be visible until it is cleared. The account dashboard is where cross-project standing conditions already live. |
| Unblock scope | Escalated PRs only | Also list and clear operator-paused PRs | An operator pause is a deliberate choice, not a fault. Listing it as blocked work would invite clearing a hold the owner meant to keep. |

## Open Questions & Future Decisions

### Deferred

1. Whether repeated unblocks on the same PR should be capped or surfaced — an
   owner can currently unblock the same PR indefinitely, which is churn rather
   than progress.
2. Whether the panel should extend beyond escalated PRs to other standing
   stops (quality-paused projects, dependency-blocked issues, runner-retry
   abandonment) under one "blocked work" heading.
3. Whether unblocking many PRs at once needs a throttle, given that PR-tier runs
   outrank queued issue work and `max_concurrent_runs` is small.

## References

- `docs/intent/focused-agent-runs/focused-agent-runs-design.md` — token fuse and
  the failure detection that trigger escalation
- `docs/intent/queue-priority-tiers/queue-priority-tiers-specs.md` —
  `QUEUE-TIER-006`, which relies on the scan source's exclusion rules
- `docs/rdrs/RDR-031-focused-agent-runs.md`
