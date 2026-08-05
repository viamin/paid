---
parent: PAID
prefix: LID-RUNS
---

# Low-Level Design: LID-Aware Agent Runs

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how agent runs recognize Linked-Intent Development projects,
> inject arrow-walking guidance, support `lid_planning`, and report coherence
> results back through pull requests.

## Purpose

RDR-051 reconciles Paid's autonomous run model with repositories that expect
Linked-Intent Development discipline. The repo already ships the core mechanics
for that reconciliation:

- project-level LID detection and storage
- prompt injection for LID repositories
- the `lid_planning` goal and optional `plan_doc_source`
- coherence-check execution for `create_pr`, `review`, and `lid_planning`
- Planning PR body generation and PR-description reporting for LID work

This segment records that shipped surface and the remaining gaps that still
need explicit LID coverage.

## Shipped Behavior

For repositories with `project.lid_mode`, prompt building appends a LID-aware
workflow section that tells the agent to read the HLD/LLDs/EARS, work
tests-first, add `@spec` annotations, run the coherence checker, and
materialize any confirmed elicited intent from enhancement into draft or
updated LLD/EARS artifacts before or alongside code changes.

Paid also ships a dedicated `lid_planning` run path. Users can queue a
docs-only planning run, optionally weight it toward a named plan doc via
`plan_doc_source`, and have PR creation generate a Planning PR body that keeps
the inferred-decision checklist visible for human review.

Finally, coherence checking is operational and intentionally soft-blocking:
failed reports are persisted on the run and surfaced in the PR body rather
than silently discarded.

## Active Gap

RDR-051 is still partially implemented. The remaining work is not "teach the
agent LID exists" but "complete the surrounding lifecycle":

- tighten the `lid_planning` output contract and plan-doc weighting rules
- add the dedicated review-goal correction loop for Planning PR feedback
- finish the stronger materialization path from elicited issue intent into LLD
  and EARS artifacts outside the native `create_pr` prompt path
- expose the same LID-aware behavior cleanly to external-agent entry points

## What this is not

- **Not LID detection itself.** Repository detection remains covered by the
  `lid-detection` segment.
- **Not a guarantee that every historical file is already tagged.** Brownfield
  `@spec` linkage still matures incrementally as runs touch each area.
- **Not a hard gate that blocks PR creation on coherence drift.** The current
  product contract is a surfaced soft-block.
