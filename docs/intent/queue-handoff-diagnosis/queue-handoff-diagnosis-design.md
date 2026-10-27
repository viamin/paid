---
parent: PAID
prefix: QUEUE-HANDOFF
---

# Low-Level Design: Queue Handoff Diagnosis

## Purpose

An empty Upcoming Queue is an observation about queued runs, not a conclusion
about open work. This segment makes the existing Auto-Pick eligibility summary
explain that distinction using the canonical candidate scope and scheduler run
state. It does not introduce a second eligibility implementation or change
admission policy.

## Diagnostic states

For each visible Auto-Pick project, the dashboard reports the number of
eligible candidates, queued runs, active runs, paused runs, and eligible
candidates that have not made the delivery handoff. Candidate eligibility is
limited to open issues; run counts retain the queue-preview scope, including
manual and pull-request work. The derived state is mechanical:

| State | Condition | Operator meaning |
| --- | --- | --- |
| `active_work` | no waiting eligible candidate and one or more active runs | healthy work is progressing |
| `runnable_not_seeded` | one or more eligible candidates lack queued or active work | the existing event/sweep seeder should recover the handoff; this takes precedence over unrelated queue entries |
| `waiting` | no eligible candidate awaits a handoff and one or more queued runs exist | scheduler backlog is represented |
| `held` | open work exists but no candidate is eligible | the dashboard identifies the held issue, its blocking work or decision, and the supported recovery route |
| `paused` | the project, account, or a run is deliberately paused | resume remains an explicit operator action |
| `unknown` | the diagnostic query cannot establish coverage | rendering reports unavailable coverage, never "no work" |

The counts are project- and user-visible only. A run is associated with an
eligible candidate by `issue_id`; manual and unrelated runs contribute to
queue coverage without hiding an unseeded candidate. The diagnostic is
read-only: no LLM call, repository
execution, remote mutation, hold clearing, or policy bypass occurs while a
dashboard frame renders.

## Recovery ownership

Reactive eligibility hooks and `AutoPickEligibilitySweepJob` remain the
bounded recovery path for `runnable_not_seeded`; their existing unique active
run constraint, project gate, budgets, pauses, and dequeue recheck remain
authoritative. Held delivery records continue through the bounded #4614
partial-closeout reconciler and existing Inbox actions. Human decisions are
not converted into retries.

For a dependency-held issue, the diagnostic preserves every currently blocking
local or external dependency so the operator can inspect the blocked issue and
each owning prerequisite. To keep a dashboard frame bounded, it selects at
most 20 held issues per project before loading that provenance; the cap never
truncates the blockers or actions for a selected issue. For a decision-held
issue, it preserves the owning feature decision or amendment hold. Feature
decisions route to their existing Inbox action; amendment holds direct the
operator to the affected issue's existing review context.
Other admission controls remain summarized rather than being inferred as a
human decision or made actionable by the diagnostic.

## Freshness and failure

The queue and diagnostic use the dashboard list cache version. Run lifecycle
broadcasts bump that version and replace the queue frame so cached queue
content is revalidated. The client marks session-cached frame content stale
until refresh succeeds. If the server-side diagnostic fails, the frame shows
unknown coverage and a refresh action rather than claiming that no work is
waiting.
