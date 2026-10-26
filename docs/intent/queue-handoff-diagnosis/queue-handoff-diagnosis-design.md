---
parent: PAID
prefix: QUEUE-HANDOFF
---

# Low-Level Design: Queue Handoff Diagnosis

## Purpose

An empty rendered Upcoming Queue is not evidence that an account has no work.
Candidate eligibility, scheduler queue contents, and active execution are
separate facts. Operators need a bounded explanation without dashboard reads
performing recovery or semantic assessment.

## Design

`Dashboard::QueueDiagnosis` composes the existing
`Dashboard::EligibilityBreakdown` canonical eligibility result with the
already-rendered queue preview and visible active runs. It reports one of four
mechanical states: queued work, runnable-but-unseeded work, healthy active work
with no waiting backlog, or no waiting work. Query failures produce `unknown`,
never an empty/healthy conclusion.

The 15-minute `AutoPickEligibilitySweepJob` remains the bounded recovery path:
it invokes `Issues::BulkEnqueueEligible`, which reassesses Paid-owned planning
holds through `FeatureIntents::ReleaseIssue` before canonical eligibility and
seeding. Rendering is read-only: it performs no remote mutation, repository
execution, or LLM call.

## Decisions

| Decision | Rationale |
| --- | --- |
| Reuse EligibilityBreakdown | It prevents a second, drifting eligibility query and preserves tenant/owner visibility. |
| Show unknown on errors | A failed diagnostic cannot prove absence of work. |
