---
parent: root
prefix: QUEUE-DELIVERY-DIAGNOSIS
---

# Design: Queue Delivery Diagnosis

## Problem

An empty Upcoming Queue is a rendered scheduler projection, not proof that a
project has no open work. Open issues, canonical auto-pick candidates, queued
runs, active runs, explicit holds, and frame freshness are distinct facts.
Operators need their relationship explained without dashboard rendering
triggering recovery, repository execution, or semantic assessment.

## Approach

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the scheduler's persisted `AgentRun` rows for the current user's visible
projects. It returns a small, inspectable snapshot with candidate, queued,
active, and open counts plus issue-level candidate provenance. The dashboard
passes its rendered queue count into that snapshot, allowing it to distinguish
an empty backend from queued backend work absent from the rendered projection.

The diagnosis has explicit states: active work with no waiting candidate,
runnable but unseeded work, configured human/dependency holds, policy/resource
pauses, stale/disconnected rendered content, and unknown coverage. A failed
query is unknown; it is never interpreted as no work. Candidate provenance is
read-only and preserves every blocking fact supplied by the canonical candidate
source rather than inventing a second eligibility implementation.

Recovery remains outside rendering. Existing event-driven enqueue paths and
the bounded `AutoPickEligibilitySweepJob` call `Issues::BulkEnqueueEligible`;
the latter also uses the established planning-hold release path. The daily
legacy partial-closeout sweep owns stale merged-delivery hold reassessment
under `PARTIAL-CLOSEOUT-028`. Those paths retain their authorization, retry,
deduplication, tenant, pause, and semantic-assessment boundaries.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Read persisted data during rendering | Run recovery or an LLM from the dashboard | Rendering must remain safe, bounded, and free of remote mutation or semantic assessment. |
| Reuse candidate source and eligibility breakdown | New dashboard-specific eligibility SQL | A second implementation would drift from admission behavior and obscure the diagnosis. |
| Surface unknown coverage | Treat query failure as an empty queue | Operational safety requires failures to remain visible. |

## Testing

Service tests cover unseeded candidates, active work, holds, pauses,
cross-tenant isolation, and read failure. Request/view tests cover the rendered
explanation and backend-nonempty/rendered-empty refresh warning.
