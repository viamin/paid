---
parent: PAID
prefix: QUEUE-DIAGNOSIS
---

# Low-Level Design: Queue Diagnosis

## Purpose

The Upcoming Queue is a view of scheduler-queued runs, not a count of open
GitHub issues. When it is empty, operators need a bounded explanation that
keeps eligible candidates, queued runs, active work, holds, and paused
admission controls distinct.

## Design

`Dashboard::QueueDiagnosis` is a read-only dashboard query. It reuses
`Dashboard::EligibilityBreakdown` for canonical candidate eligibility and reads
the scheduler's queued and active run scopes separately. It reports one of:
`backend_queue_nonempty`, `stale_dashboard`, `runnable_unseeded`,
`healthy_active_work`, `genuine_holds`, `resource_policy_paused`,
`healthy_no_waiting_work`, or `unknown`.

The query returns bounded issue-level blocker records. A record may have more
than one mechanically derived blocker and links back to the issue; it never
infers semantic reasons from issue text. Human decisions remain in Inbox and
normal dependency, pause, and authorization controls remain authoritative.

The existing event-driven re-enqueue paths and `AutoPickEligibilitySweepJob`
remain the recovery mechanism. They may release workflow-owned planning holds
through `FeatureIntents::ReleaseIssue` and seed canonical candidates, but no
dashboard request performs recovery, repository work, remote mutation, or an
LLM request. Failures in the diagnosis query produce `unknown`, never an empty
work conclusion.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Reuse eligibility breakdown and scheduler scopes | Derive eligibility from labels in the view | The candidate source and scheduler remain the canonical authorities. |
| Read-only dashboard diagnosis | Run recovery while rendering | Rendering must remain bounded and cannot spend authority or agent budget. |
| Explicit stale-render state | Treat an empty rendered list as an empty backend | Cached/dashboard transport state can diverge from the live scheduler. |
