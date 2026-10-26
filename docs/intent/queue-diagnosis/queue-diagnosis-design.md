---
parent: PAID
prefix: QUEUE-DIAGNOSIS
---

# Queue diagnosis

## Purpose

An empty Upcoming Queue is a projection of scheduler-ready queued runs, not a
claim that no work exists. Operators need a bounded explanation which preserves
the separate facts of eligible candidates, queued work, active work, and normal
admission holds.

## Design

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the visible projects' queued and active `AgentRun` counts. It has no mutation,
agent-harness call, repository execution, or remote interaction. A failure to
read canonical data is an `unknown` diagnosis, never an empty-work conclusion.

States are mechanical and mutually ordered: intentional resource or policy
pause; runnable work not seeded; healthy active work with no waiting backlog;
genuine admission holds; and idle. The queue display only requests a diagnosis
when the scheduler preview itself is empty, preserving the backend queue as the
authority when it is non-empty.

Recovery stays with existing owners. `AutoPickEligibilitySweepJob` is the
bounded, concurrency-limited path which seeds eligible unqueued work; event
paths trigger the same policy. `PartialCloseouts::ReconcileLegacy` owns stale
merged-delivery planning-hold reassessment and routes human prerequisites to
Inbox. Dashboard rendering cannot invoke either service.

## Decisions and alternatives

| Decision | Alternative | Rationale |
| --- | --- | --- |
| Compose the established eligibility breakdown | Create another eligibility query | One canonical candidate projection prevents dashboard/scheduler drift. |
| Keep recovery outside rendering | Reassess holds or seed runs on page load | Rendering has no delegated mutation authority and must not spend LLM budget. |
