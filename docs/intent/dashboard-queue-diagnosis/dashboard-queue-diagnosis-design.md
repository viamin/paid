---
parent: PAID
prefix: DASHBOARD-QUEUE-DIAGNOSIS
---

# Low-Level Design: Dashboard Queue Diagnosis

## Purpose

An empty Upcoming Queue is not itself a failure. The dashboard must distinguish
eligible work that has not been seeded, work already in flight, deliberate
holds, and unavailable coverage without mutating scheduling state during a
request.

## Design

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the scheduler's queued and active run records for the same visible projects.
It reports candidate, queued, and active counts independently. Its states are
`runnable_unseeded`, `active_work`, `dependency_or_decision_hold`,
`no_waiting_work`, and `unknown`. The request is read-only: event handlers and
`AutoPickEligibilitySweepJob` remain the bounded recovery paths. Query failure
is rendered as unknown coverage, never as an empty backlog.

## Decisions & Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Compose established dashboard services | Reimplement candidate eligibility | Keeps displayed candidates aligned with scheduler admission. |
| Diagnose only on reads | Run recovery from dashboard rendering | Rendering must not invoke semantic assessment, remote mutation, or queue writes. |
