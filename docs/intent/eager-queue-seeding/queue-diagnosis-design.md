---
parent: eager-queue-seeding
prefix: EAGER-QUEUE-DIAG
---

# Low-Level Design: Queue Diagnosis

## Purpose

An empty queue preview is a rendered observation, not a statement about open
work. The dashboard projects existing eligibility and scheduler facts into a
bounded explanation without making network calls, running repositories, or
mutating delivery state during rendering.

## Design

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the scheduler's `schedulable_queued_with_priority` and `capacity_inflight`
scopes, limited to projects the viewer can already see. It reports separate
candidate, queued, and active counts. A zero preview with queued backend rows
is surfaced as a refresh mismatch; a failure is `unknown`, never healthy.

States are mechanical: `active_work`, `runnable_unseeded`, `held`, `paused`,
`empty`, and `unknown`. Held work links to the existing Inbox; recovery and
semantic reassessment remain owned by their existing asynchronous services.
The diagnosis does not clear labels, change policy, assess repositories, or
create runs.

## Decisions

- **Compose current projections rather than duplicate eligibility SQL.** This
  preserves the candidate contract and keeps the queue diagnostic read-only.
- **Expose unknown coverage.** A failed read cannot establish that a queue is
  empty, so the only safe dashboard action is refresh.
