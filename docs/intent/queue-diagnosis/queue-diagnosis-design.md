---
parent: PAID
prefix: QUEUE-DIAGNOSIS
---

# Queue Diagnosis

## Purpose

Explain an empty Upcoming Queue without conflating open GitHub issues, eligible
candidates, queued runs, and active delivery work. Operators need a bounded,
tenant-scoped explanation and a supported recovery path, not a claim that an
empty rendered list proves there is no work.

## Design

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the scheduler's persisted `AgentRun` state. It is a read-only dashboard
projection. It may not invoke an LLM, execute a repository, call GitHub, or
change release/hold state while rendering.

The projection reports one of these states: waiting work, healthy active work,
runnable-but-unseeded work, resource/policy pause, genuine hold, healthy empty,
or unknown coverage. A database/query failure is unknown coverage and offers a
refresh action; it is never represented as a healthy empty queue.

For non-waiting work the projection includes a bounded issue list. It preserves
multiple dependency/feature-hold reasons, the last local assessment timestamp,
and the next supported action. Human decisions remain in Inbox; this view only
links to the underlying issue and names the action.

The existing `AutoPickEligibilitySweepJob` remains the recovery authority for
eligible-but-unseeded work and stale confidence planning-hold projections. Its
existing gate, idempotent enqueue behavior, 15-minute cadence, and concurrency
limit bound retries, cost, and duplicate delivery. No dashboard request can
cause that recovery.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Reuse eligibility breakdown and auto-pick sweep | Keeps the dashboard aligned with canonical admission and recovery behavior. | A new dashboard-only eligibility query could drift from scheduler truth. |
| Unknown on query failure | A failed read is not evidence of no work. | Showing an empty state would hide an outage. |
| Read-only render | Remote mutations and semantic assessment need durable background authority. | Inline recovery would make a page refresh execute work. |

## Testing

Service specs cover eligible unseeded work, active work, dependency holds,
unknown coverage, and tenant isolation. Existing queue-preview cache-version
regression coverage verifies that queued backend changes refresh the preview
rather than making stale dashboard content look current.
