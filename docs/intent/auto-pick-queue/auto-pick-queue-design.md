---
parent: PAID
prefix: AUTO-PICK-QUEUE
---

# Low-Level Design: Auto-Pick Queue

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the queue-seeding lifecycle for project Auto-Pick.

## Purpose

Auto-Pick turns eligible project issues into queued automatic agent runs. The
project toggle is the operator control for that lifecycle: enabling it seeds
eligible work, and disabling it stops future automatic picks and drains queued
automatic picks.

The additive exception is tracked under
`docs/intent/automation-activation-labels/`: when the project toggle is off,
an issue-scoped activation label may still enable exactly one issue without
changing the background queue semantics for every other issue.

## Disable Semantics

Queued Auto-Pick runs are cancelled, not deleted, when Auto-Pick is disabled.
That preserves run history while removing the work from scheduler and dashboard
queue views. The drain applies to queued runs only (`status = "queued"`) so a
run that has already started executing is left to the normal cancellation and
execution controls.

Some Auto-Pick-adjacent enhancement rechecks are queued as automatic
`enhance_issue` runs by the GitHub sync path without the `auto_pick` flag set.
Those runs still belong to the Auto-Pick lifecycle for queue-drain purposes and
are cancelled when Auto-Pick is disabled. Manual `enhance_issue` runs remain
queued.

Enqueue paths may bypass broader project gates after a caller has already
established eligibility, but they must still respect the canonical
`auto_pick_enabled` switch at call time so stale sync or retry work cannot
recreate queued Auto-Pick runs after the operator turns the feature off.

## Issue-analysis cooldown gating

Auto-Pick eligibility also respects issue-level `analyze_issue` cooldowns
recorded after provider exhaustion. A failed issue that is otherwise eligible
must stay out of the candidate pool until its persisted next-attempt time,
unless the owner's issue-analysis runner configuration / runner-health context
has changed since that cooldown was recorded. Manual retries do not consult
this gate.

A needs-input label is an independent, always-on eligibility exclusion. It
applies regardless of `paid_state`, so a stale local state cannot schedule work
while a user clarification remains pending.

## GitHub-open authority and visibility

An issue that remains open on GitHub is never removed from Auto-Pick merely
because Paid has reached an internal workflow state. Candidate selection and
the project issue lifecycle use the same state-neutral scope, so
`recommend_close`, `manual_review`, `needs_input`, `completed`, and stale
`in_progress` rows remain actionable when no other guard applies. Active runs,
open dependencies, explicit label controls, pauses, and the durable
no-code-required / merged-PR safeguards remain separate guards.

The project issue list displays each issue's Paid state beside its lifecycle
badge. The dashboard's eligibility breakdown continues to report the actual
guards that exclude open issues, so a workflow-state drift cannot become an
invisible block.
