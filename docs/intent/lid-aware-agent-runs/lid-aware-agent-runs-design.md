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
the inferred-decision checklist visible for human review. The run path now
carries two explicit contracts:

- **Authored-intent weighting (LID-RUNS-005).** Named plan docs are authored
  intent, not a free-form hint. The prompt instructs the agent that decisions
  sourced from named plan docs map into HLD/LLD/EARS as authored rationale and
  MUST NOT carry an `[inferred]` marker; only code-sourced rationale is
  `[inferred]`.
- **Output artifact contract (LID-RUNS-007).** A successful run must produce the
  required docs-only artifact set, validated run-kind aware: adoption runs (no
  `lid_mode`) require the HLD, at least one LLD and its EARS specs, the `## LID`
  block, and `docs/arrows/index.yaml`; refinement runs (`lid_mode` present)
  require at least one LLD and its EARS specs. The contract is server-side
  enforced at PR creation alongside the docs-only allowlist.

Finally, coherence checking is operational and intentionally soft-blocking:
failed reports are persisted on the run and surfaced in the PR body rather
than silently discarded.

External-agent entry points now expose the same contract explicitly instead of
assuming callers will infer it from run metadata:

- the authenticated project-interop API exposes the effective LID mode,
  detection metadata, and the rendered LID workflow contract for the project
- the read-only MCP `get_project` tool returns the same LID contract so remote
  agents using Paid's MCP surface can discover it without out-of-band docs
- `lid_planning` is explicitly supported for external orchestration through the
  existing run-trigger surface, including named plan docs
- Planning-PR correction remains explicitly unsupported for external agents
  until the dedicated correction loop in `LID-RUNS-004` ships

## Active Gap

RDR-051 is still partially implemented. The remaining work is not "teach the
agent LID exists" but "complete the surrounding lifecycle":

- add the dedicated review-goal correction loop for Planning PR feedback
  (LID-RUNS-004)
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
