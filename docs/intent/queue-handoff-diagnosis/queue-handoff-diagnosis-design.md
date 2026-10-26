---
parent: PAID
prefix: QUEUE-HANDOFF
---

# Low-Level Design: Queue Handoff Diagnosis

## Purpose

An empty Upcoming Queue is not a conclusion. The dashboard distinguishes the
candidate pool, queued runs, active runs, and admission holds so an operator
can see whether work is progressing, needs seeding, is deliberately held, or
cannot be diagnosed.

## Design

`Dashboard::EligibilityBreakdown` remains the owner of the visible candidate
counts. It derives eligibility through the canonical Auto-Pick candidate scope
and separately counts visible queued and running runs. `Dashboard::QueueDiagnosis`
combines those facts without performing mutations or remote calls while a
dashboard frame renders.

The diagnosis states are: `healthy_active_work`, `runnable_unseeded`,
`blocked`, `paused`, and `unknown`. A queued run is distinct from an eligible
candidate; a running run is progress, not an empty-queue failure. Blocked
issues retain every mechanical blocker that is locally observable (active work,
dependency, needs-input or configured skip label) and link to the established
Inbox action when human input is required.

The existing event paths and `AutoPickEligibilitySweepJob` own recovery. The
sweep is bounded by its GoodJob concurrency limit and invokes
`BulkEnqueueEligible`, which releases confidence/planning holds before the
canonical admission check. It bumps the dashboard list cache only when it
creates a run. Errors are surfaced as `unknown`; they are never interpreted as
an empty candidate pool.

## Decisions

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Diagnose from existing candidate and scheduler scopes | Reimplement eligibility in the dashboard | One authoritative admission policy prevents dashboard explanations from drifting from scheduling. |
| Keep recovery out of rendering | Trigger enqueue/LLM work from frame requests | Rendering must be safe, bounded, and read-only; events and the sweep already have delegated recovery authority. |
