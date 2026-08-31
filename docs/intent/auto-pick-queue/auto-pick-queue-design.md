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

## Completed-issue recovery vs. agent-declared terminal completions

`DefaultCandidateSource` re-includes open, `paid_state: "completed"` issues
whose last automatic run finished without a PR, on the theory the run may
have failed transiently and is worth retrying. That recovery path is a poor
fit for an issue an agent explicitly declared complete without a code change
(see the no-output-issue-handling segment's `no_code_required` outcome):
retrying would just loop, since the agent will typically reach the same
conclusion again. Such issues are stamped with `no_code_required_at`, which
candidate selection excludes permanently and regardless of `paid_state` —
the same always-on style already used for merged-PR-linked issues — so only a
manually triggered run can pick the issue up again.
