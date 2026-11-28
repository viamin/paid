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

This segment records the shipped surface that the 2026-08-23 RDR-051 closeout
audited as fully implemented.

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
  `[inferred]`. Queued-run prompt preparation includes both `plan_doc_source`
  and named docs in run metadata.
- **Output artifact contract (LID-RUNS-007).** A successful run must produce the
  required docs-only artifact set, validated run-kind aware: adoption runs (no
  `lid_mode`) require the HLD, at least one LLD and its EARS specs, the `## LID`
  block, and `docs/arrows/index.yaml`; refinement runs (`lid_mode` present)
  require at least one LLD and its EARS specs. The contract is server-side
  enforced at PR creation alongside the docs-only allowlist. Planning prompts
  enumerate allowed paths and require adoption configuration in root `AGENTS.md`
  or `CLAUDE.md` with an exact `## LID` heading and Mode/Version bullets, matching
  repository LID detection.

Finally, coherence checking is operational and intentionally soft-blocking:
failed reports are persisted on the run and surfaced in the PR body rather
than silently discarded.

### Spec-ID allocation collision detection (LID-RUNS-008..011)

Independently developed branches can allocate the same EARS ID for different
new claims. When one branch merges and a sibling later integrates, the
duplicates land without a Git conflict (the declarations are separate
additions in separate hunks), leaving duplicate declarations and ambiguous
Code/Test arrows that only surface during review (#5383: PR5370 vs merged
PR5294 on `SUBSCRIPTION-RUNNER-AUTH-008`; PR5283 vs main on
`CONTAINER-RUNTIME-054`; #5322 vs merged #5291 on `FOCUSED-RUN-011`).

The coherence check includes a structural branch-vs-target analysis, reported
in the same soft-block channel as the existing sections:

- **Inputs.** `Lid::CoherenceCheck` exports the run's recorded integration
  base (`agent_run.base_commit_sha`) as `LID_BASE_SHA` and the merge target
  (`project.default_branch`) as `LID_TARGET_BRANCH` into the container
  command. `bin/coherence-check.mjs` resolves the target ref from that env
  (or auto-detects `origin/HEAD` / `origin/main` / `origin/master` when run
  standalone), refreshes the target tip with a bounded `--depth 1` fetch
  (best-effort; local ref on failure), and resolves the base from
  `LID_BASE_SHA`, falling back to `git merge-base <target> HEAD`. When
  neither resolves, the section is skipped with an advisory note — no
  findings, no failure.
- **Collision rule (structural).** A collision is an ID whose declaration is
  new on both sides since the base — present in the working tree (the
  proposed head, uncommitted work included) and newly declared on the target
  tip, absent from the base tree. IDs declared at the base are excluded:
  an amended or unchanged shared claim is legitimate (LID workflow Phase 3:
  "Spec IDs are stable. Revisions mutate text, not IDs"). Two ancestry
  refinements keep reconciled states clean: when the target tip is already an
  ancestor of HEAD (the branch merged the target), independent-allocation
  detection is skipped in favor of tree-level duplicate scanning; and a head
  declaration whose text is byte-identical to the target's declaration for
  the same ID is treated as an adopted claim, not an independent allocation.
  No keyword or semantic content judgments are used.
- **Duplicate declarations in the proposed integration tree.** The check
  simulates the textual integration with `git merge-tree --write-tree`
  (building a snapshot commit from the working tree through a temporary
  index, so uncommitted agent work is included and the real index is never
  touched) and reports IDs declared at more than one site in the merged tree
  where at least one site is new since the base. This is what catches the
  auto-merge-without-conflict case. When `merge-tree` is unavailable, the
  check falls back to scanning the working tree and notes the limitation.
- **Evidence.** Findings cite the colliding ID, the head and target
  declaration sites (file:line plus the declaration text), the head's
  `@spec` Code/Test annotation sites (so the incoming claim and its
  annotations are renumbered together), and the base/head/target revisions.
  The parser persists these as `collision_details` alongside the existing
  counts, and the PR soft-block section renders them.
- **Advisory posture unchanged.** Collision counts join the existing
  coherence counts in the same failed/soft-block report; they do not create a
  new merge blocker, and unrelated advisory findings stay advisory exactly as
  before. The intent-rec conformance merge guard is a separate mechanism and
  is not extended here.

External-agent entry points now expose the same contract explicitly instead of
assuming callers will infer it from run metadata:

- the authenticated project-interop API exposes the effective LID mode,
  detection metadata, and the rendered LID workflow contract for the project
- the read-only MCP `get_project` tool returns the same LID contract so remote
  agents using Paid's MCP surface can discover it without out-of-band docs
- `lid_planning` is explicitly supported for external orchestration through the
  existing run-trigger surface, including named plan docs
- Planning-PR correction support is advertised to external agents through the
  same LID contract once the dedicated review-goal correction loop shipped

## Closeout Status

RDR-051 is implemented. The follow-up gaps that previously kept this segment in
partial status are now shipped:

- the review-goal correction loop for Planning PR feedback (`LID-RUNS-004`)
- the elicited-intent materialization path in LID-enabled implementation prompts
- the external-agent LID contract through the interop API and MCP surfaces

Incremental brownfield `@spec` tagging remains the intended operating posture,
not a closeout blocker.

## What this is not

- **Not LID detection itself.** Repository detection remains covered by the
  `lid-detection` segment.
- **Not a guarantee that every historical file is already tagged.** Brownfield
  `@spec` linkage still matures incrementally as runs touch each area.
- **Not a hard gate that blocks PR creation on coherence drift.** The current
  product contract is a surfaced soft-block.
