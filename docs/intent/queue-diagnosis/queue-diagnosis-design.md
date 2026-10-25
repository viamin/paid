---
parent: PAID
prefix: QUEUE-DIAGNOSIS
---

# Queue Diagnosis

## Purpose

The Upcoming Queue is a projection of queued `AgentRun` records, not a count
of every open issue. When it is empty, operators need a bounded explanation
that keeps candidate eligibility, queued work, active work, and policy holds
separate.

## Design

`Dashboard::QueueDiagnosis` reads the same canonical
`DefaultCandidateSource.eligible_scope` used by the scheduler together with
queued and capacity-inflight `AgentRun` rows. It is account/owner scoped in the
same manner as `QueuePreview`. It classifies each visible auto-pick project as
healthy active work, runnable-but-unseeded work, a human/decision hold, a
resource or policy pause, or healthy without a waiting backlog. Database
failure is shown as unknown coverage, never as an empty result.

The read model runs only when the queue preview has no visible rows. It has no
LLM call, repository execution, sync, or mutation. Item links provide the
issue-level source of a hold and Inbox remains the action surface for human
input.

Recovery is deliberately not owned by dashboard rendering. The existing
bounded `AutoPickEligibilitySweepJob` is the periodic mechanical recovery:
it invokes `Issues::BulkEnqueueEligible`, which preserves project gates,
holds, budgets, authorization, duplicate-run protection, and dequeue-time
checks. Legacy partial-closeout reassessment remains owned by
`LegacyPartialCloseoutReconciliationSweepJob`; diagnosis does not clear labels
or override policy.

## Decision and alternatives

| Decision | Alternative | Rationale |
| --- | --- | --- |
| Read canonical scheduler data at render time | Infer queue state from open issue totals | Open issues and queued runs are different facts; candidate scope prevents dashboard/scheduler drift. |
| Reuse periodic admission recovery | Recover directly from the dashboard | Rendering must be safe, bounded, and non-mutating. |
