---
parent: PAID
prefix: QUEUE-DIAG
---

# Low-Level Design: Queue Diagnosis and Stalled-Handoff Recovery

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how Paid explains an empty or unexplained Upcoming Queue
> (#4619) and how it detects a delivery handoff that stopped progressing.
> The sibling segments `eager-queue-seeding` (how eligible issues become
> queued runs), `partial-closeout-recovery` (how a delivered-but-unresolved
> issue is recovered) and `dashboard-frame-caching` (how dashboard tiles are
> revalidated) own their parts of the contract.

## Problem

The operator reported an empty Upcoming Queue against 45 open Paid issues. A
diagnostic snapshot counted 33 label-excluded issues, 3 in progress and 9
other exclusions. During the investigation the queue backend returned five
queued runs, and releasing two verified stale planning holds created more
work.

Those are four different facts — open issue count, candidate eligibility,
queued runs, and rendered queue state — and Paid rendered none of them
together. An empty queue looked like a dead end: the operator could not tell
whether the queue was empty because nothing was eligible, because eligible
work was never seeded, because work was genuinely held by a dependency or a
human decision, because a policy or resource pause was in force, or because
the diagnosis itself could not be computed. The investigation required
manual database work, and nothing in the product detected a handoff that had
stopped progressing.

## Scope

This segment delivers the *explanation* and the *bounded recovery*. It does
not change eligibility rules, admission controls, queue ordering, or the
authority of any existing recovery path.

## Diagnostic states

`Dashboard::QueueDiagnosis` derives exactly one primary state for the visible
queue from canonical data only — the auto-pick candidate scope
(`Automation::Strategies::AutoPick::DefaultCandidateSource`), the scheduler
scope (`AgentRun.schedulable_queued_with_priority`) and the persisted issue
rows:

| State | Meaning |
|---|---|
| `healthy` | Work is queued/running and there is no waiting backlog, or there is genuinely nothing open to do. An empty queue is **not** a failure. |
| `runnable_not_seeded` | Eligible candidates exist that no queued or running run covers — the handoff from eligibility to the scheduler never happened. |
| `blocked` | No runnable work, but open issues are held by genuine dependency or decision blockers. |
| `paused` | No runnable work, and the only reasons are resource or policy pauses (project/scheduler/quality pause, no feasible runner tier, deliberate operator hold). |
| `unknown` | The diagnosis could not be completed, or no project's issue coverage is known. Unknown coverage is never reported as "no work". |

The state is chosen by precedence: `unknown` → `runnable_not_seeded` →
`blocked` → `paused` → `healthy`. A project whose issue sync is missing or
stale contributes *unknown coverage* rather than an empty count, so a failed
sync can never be read as proof that no work exists.

The diagnosis reports counts that keep the four facts apart:

- `eligible` — candidates the canonical scope admits right now.
- `queued` — runs the scheduler scope still holds.
- `running` — runs in flight (claimed or running).
- `blocked` — open issues with at least one blocker.
- `paused` — open issues held only by resource/policy pauses.
- `unseeded` — eligible candidates with no queued or running run.

`eligible` and `queued`/`running` are never summed: a queued run's issue is
already excluded from the candidate scope by the "work in flight" guard.

## Issue-level blocker provenance

`Issues::QueueBlockers` explains one issue. It is deliberately **read-only**:
it never calls `FeatureIntents::RunAdmission` (which reconciles a planning
hold and therefore mutates GitHub and the database), never calls an LLM, and
never executes repository code. The read-only hold projection
`FeatureIntents::IssueHold` supplies the feature/planning-hold blocker.

Every blocker carries:

- `code` — a stable machine-readable reason.
- `message` — one sentence naming the condition.
- `owner` — the work or decision that owns the block (the blocking issue
  numbers, the feature that holds the issue, the operator, the runner
  capacity, the merged pull request).
- `recovery` — the next supported action, phrased as an action rather than a
  diagnosis.
- `evidence` — the persisted facts the blocker was derived from.

Blockers are **additive**: simultaneous guards are all reported rather than
the first one concealing the rest. The blocker list is the "owning work" and
"next supported action" the dashboard renders per issue.

The last successful stall assessment for the issue (see below) is read from
`queue_stall_assessments` and rendered as the issue's "last assessed"
provenance, so an operator can tell an unexamined issue from one that was
examined and found blocked.

## Stalled delivery handoffs

A *delivery handoff* is the transition of work from one stage to the next:
eligibility → scheduler, planning hold → released, delivery → resolution.
`QueueStalls::Detector` recognises three non-progressing handoffs with
mechanical conditions only (no semantic judgment):

| Reason | Condition | Recovery |
|---|---|---|
| `unseeded_runnable` | The issue is in the project's candidate scope, the project has auto-pick enabled, the auto-pick project gate is open, and no run in `AgentRun::AUTO_PICK_BLOCKING_STATUSES` covers it. | `Issues::EnqueueEligible` |
| `stale_planning_hold` | The issue serves an unreleased confidence-driven feature link whose hold is recorded (`held`, `pending` or `reconciliation_failed`), the hold record has not changed for `STALE_HOLD_AGE`, and no run covers the issue. | `FeatureIntents::ReleaseIssue` |
| `unresolved_delivery` | The issue carries terminal delivery evidence (a merged pull request linked back to it), is not in the candidate scope, has no run in flight, and has no open continuation request. | the existing agent_harness recovery path (`PartialCloseouts::ReconcileLegacy`) |

The recovery services are the existing ones, invoked within their own
authority: `Issues::EnqueueEligible` still honours the auto-pick switch and
the project gate, `FeatureIntents::ReleaseIssue` still refuses to release a
hold whose scoped readiness does not pass, and the closeout reconciler still
writes no `paid_state` change and never closes an issue. Nothing here
removes planning labels wholesale, overrides rollout or approval policy, or
bypasses trust, budget, tenant, or phase controls.

## Deduplication, bounds and cost

`queue_stall_assessments` is the durable record of a stall assessment:

- `issue_id`, `reason_code`, `state_digest` — the dedup key. The digest is a
  SHA-256 of the *relevant* state (the blockers and the revisions they were
  derived from), so a changed blocker set is a new assessment while an
  unchanged one is not.
- `outcome` — `recovered`, `blocked`, `skipped`, or `failed`.
- `attempt_count` — the number of times this exact state was assessed.
- `assessed_at` — when it happened.

A unique index on `(issue_id, reason_code, state_digest)` makes repeated
assessment of unchanged state a no-op: the sweep records the outcome once and
never repeats the recovery for the same state. A changed blocker set produces
a new digest and is assessed again.

Bounds:

- The sweep processes at most `MAX_STALLS` stalls per invocation and at most
  `MAX_SEMANTIC_RECOVERIES` accounts per invocation.
- The semantic branch delegates to `PartialCloseouts::ReconcileLegacy`, which
  owns its own batch size, advisory lock and one-day retry gate; the sweep
  never performs an LLM call itself.
- `attempt_count` is capped at `MAX_ATTEMPTS`; beyond the cap the assessment
  is recorded as `skipped` and the issue is surfaced for a human instead of
  being retried forever.
- The job uses GoodJob concurrency control, so overlapping sweeps cannot
  stack.

## Human decisions

A stall whose owner is a human (manual review, needs-input, approval-gated
feature) is **not** recovered by the sweep. It is surfaced with a link to the
existing actionable Inbox lane that already owns that decision
(`Inbox::Queue::MANUAL_REVIEW_KIND`, `Inbox::Queue::CLARIFYING_QUESTIONS_KIND`,
`Inbox::Queue::FEATURE_DECISION_KIND`). The sweep never creates a second
Inbox item, a duplicate follow-up issue, or a no-change audit for a state it
has already assessed.

## Freshness and stale dashboard content

The dashboard tile is a Turbo frame with a stale-while-revalidate cache
(`dashboard-frame-caching`). The diagnosis tile additionally carries the
server-side `generated_at` of the snapshot it rendered, so the operator can
see how old the content is. When a tile refresh fails, the frame is marked
(`data-dashboard-frames-refresh-failed`) and the tile shows an explicit
"refresh failed — showing the last known state" notice, so stale content can
never appear current.

## Failure semantics

- A failed query, a failed sync, or an exception inside the diagnosis
  produces the `unknown` state with a recovery action. It never produces
  "no work".
- A failed recovery records a `failed` assessment with the error, and the next
  sweep retries it only when the relevant state changed (new digest) or the
  retry gate allowed it.

## Alternatives considered

- *A second eligibility query for the dashboard*: rejected — the canonical
  candidate scope is the only eligibility authority; the diagnosis reads it
  and the existing `Dashboard::EligibilityBreakdown` /
  `Dashboard::QueuePreview` surfaces keep their ownership.
- *Treating every empty queue as a failure*: rejected — an empty queue with
  nothing eligible is a healthy state.
- *Resolving holds inside the dashboard render*: rejected — rendering must
  not mutate GitHub, the database, or run semantic assessment.
- *A new Inbox lane for queue stalls*: rejected — the existing actionable
  lanes already own human decisions; a second lane would duplicate them.
