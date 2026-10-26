---
parent: PAID
prefix: QUEUE-HANDOFF
---

# Low-Level Design: Queue Handoff Diagnosis

## Purpose

An empty rendered Upcoming Queue is not, by itself, evidence that there is no
work. Open issues, eligible candidates, queued runs, and running runs are
separate facts. The dashboard therefore derives an account-and-owner-scoped
diagnosis from the existing eligibility and scheduler data instead of treating
an empty preview as a failure.

## Design

`Dashboard::QueueDiagnosis` composes `Dashboard::EligibilityBreakdown` with
the authoritative `AgentRun` status rows visible to the current user. It does
not recreate candidate eligibility rules or invoke recovery work while a
dashboard is rendering.

The diagnosis distinguishes: queued work, active work with no waiting
backlog, eligible work that has not been seeded, intentional policy/resource
pauses, genuine candidate holds, and unavailable coverage. Counts retain the
separation between candidates and queued/running runs. A database/query
failure becomes `unavailable`; it must never be rendered as an empty backlog.

The existing event-driven enqueue paths and bounded `AutoPickEligibilitySweepJob`
remain the recovery authority. The existing partial-closeout recovery path owns
semantic reassessment and Inbox routing; the dashboard only links operators to
the existing actionable surfaces.

## Boundaries

The diagnosis uses the same owner visibility rule as `QueuePreview` and does
not expose another tenant's projects or runs. It honors scheduler and quality
pauses and does not clear labels, bypass admission policy, execute repository
code, contact a provider, or mutate remote state.
