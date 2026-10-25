---
parent: PAID
prefix: QUEUE-HANDOFF
---

# Low-Level Design: Queue Handoff Diagnosis

## Purpose

An empty Upcoming Queue is not itself an outage. It can mean that work is
running, that all open work is deliberately held, or that eligible work was
not handed to the scheduler. The dashboard must distinguish those facts using
the same eligibility and scheduler records that admit work.

## Diagnosis

`Dashboard::QueueDiagnosis` combines `Dashboard::EligibilityBreakdown` with
the visible queued and in-flight `AgentRun` rows. It reports one of five
mechanical states:

| State | Condition | Operator meaning |
| --- | --- | --- |
| `active_work` | no waiting eligible issue and active work exists | healthy; work is progressing |
| `unseeded_work` | an eligible issue has no queued or in-flight automatic run | the handoff needs recovery |
| `held_work` | open work exists but all candidates are excluded | inspect the established eligibility and Inbox controls |
| `empty` | no open work or work visible to this user | no waiting backlog |
| `unknown` | an eligibility or scheduler read fails | refresh; no absence conclusion is made |

The diagnosis is read-only. It never calls an LLM, executes repository code,
or mutates remote state while rendering. The existing event paths and
`AutoPickEligibilitySweepJob` own recovery: they use `Issues::BulkEnqueueEligible`,
which rechecks policy, pauses, authorization, holds, duplicate work, and the
canonical candidate scope before creating an idempotent queued run.

## Visibility and freshness

The service scopes every query through the requesting user's account and
visible project ownership, including the established fallback-owner case. It
returns scheduler counts separately from eligible counts. The frame shares the
dashboard list cache version, so a successful seeding or cancellation can
invalidate stale queue content without representing stale data as current.
