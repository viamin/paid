---
parent: root
prefix: QUEUE-DIAGNOSIS
---

# Design: Queue diagnosis

> Segment: queue-diagnosis · Status: implemented
> Specs: [queue-diagnosis-specs.md](queue-diagnosis-specs.md)

## Problem

An empty Upcoming Queue is a presentation of queued `AgentRun` records, not a
statement that a project has no open issues. Operators need to distinguish
normal active work, an unseeded eligible backlog, deliberate holds and pauses,
and unavailable diagnostic coverage without dashboard rendering mutating work.

## Design

`Dashboard::QueueDiagnosis` is a read-only projection next to the existing
`EligibilityBreakdown` and `QueuePreview` services. It uses the same eligible
candidate source and the scheduler's queued scope, scoped to the signed-in
user's visible auto-pick projects. It returns counts plus bounded issue-level
blocker provenance for dependency and feature-decision holds.

The states are mechanical and ordered: `runnable_unseeded` when eligible work
has neither queued nor active work; `healthy_active` when active work explains
the absence of a waiting backlog; `held` for unresolved dependencies or
feature-decision holds; `paused` for deliberate scheduler/quality pauses; and
`unknown` if this read model cannot be built. A failed query is never rendered
as no work.

The dashboard only renders this projection. Recovery remains event-driven and
bounded by `Issues::BulkEnqueueEligible` and `AutoPickEligibilitySweepJob`,
which already reuses candidate admission, planning-hold reconciliation,
deduplication, project gates, and concurrency controls. Rendering never
enqueues work, calls an LLM, executes a repository, or mutates a remote.

## Testing

`spec/services/dashboard/queue_diagnosis_spec.rb` covers unseeded eligible
work, active work, dependency holds, paused work, unknown coverage, and
account/owner visibility. `spec/requests/dashboard_spec.rb` covers rendering
the diagnostic alongside an empty queue.
