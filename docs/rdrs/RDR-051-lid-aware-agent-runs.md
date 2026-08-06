# RDR-051: Linked-Intent Development (LID) Integration

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-04
- **Status**: Partially Implemented
- **Type**: Architecture + Process
- **Priority**: P1
- **Related Issues**: #3161 (reconciliation), #3198 (`lid_planning` output contract), #3199 (Planning PR review corrections), #3200 (elicited-intent materialization), #3201 (external-agent exposure)
- **Related Tests**: `spec/services/projects/detect_lid_mode_spec.rb`, `spec/services/lid/inject_into_prompt_spec.rb`, `spec/services/prompts/build_for_issue_spec.rb`, `spec/services/prompts/build_for_lid_planning_spec.rb`, `spec/temporal/activities/create_pull_request_activity_spec.rb`, `spec/services/lid/coherence_check_spec.rb`

## Implementation Status

Partially implemented as of **August 4, 2026**. The original draft text is stale: the
project data model, repository detection, override/redetect UI, LID-aware prompt injection,
seeded prompt fragment, vendored checker, LID-aware enhancement question style, elicited
intent prompt section, `lid_planning` goal, planning prompt builder, Planning-PR title/body
path, docs-only changed-file guard, and PR-description LID phase reporting are all shipped.

Phase-by-phase reconciliation:

- **Phase 0 (detection + data model)**: shipped. `projects.lid_mode`,
  `projects.lid_detection`, and `projects.lid_mode_overridden` exist; detection runs from
  the project-conventions collector and project settings support override plus re-detect.
- **Phase 1 (LID-aware implementation runs)**: shipped. `Lid::InjectIntoPrompt` is wired
  into `Prompts::BuildForIssue` and `Prompts::BuildForPr`, the
  `coding.lid_aware_section` prompt exists, the agent image vendors `docs/lid/` and
  `bin/coherence-check.mjs`, and PR descriptions append LID phase/coherence reporting.
- **Phase 2 (LID-aware issue enhancement)**: partially shipped. Enhancement already asks
  plain-language intent questions for all projects, and LID projects surface answered
  clarifying questions as `# Elicited Intent` in `create_pr` prompts. The stronger
  materialization promise remains open in #3200.
- **Phase 3 (`lid_planning` goal)**: shipped. The goal exists end-to-end with
  prompt building, UI/API trigger surfaces, stored `plan_doc_source`, Planning-PR
  body handling, docs-only diff validation, and an explicit run-kind-aware
  output contract (`Lid::PlanningContract`) that enforces the required artifact
  set for adoption versus refinement runs, plus authored-intent weighting for
  named plan docs (#3198).
- **Phase 4 (Planning PR confirmation via review)**: partially shipped. Planning PRs can
  carry the expected checklist, but the dedicated `review`-goal correction loop for
  `[inferred]` review feedback remains open in #3199.
- **Phase 5 (conversion polish, coherence gating, incremental tagging)**: partially
  shipped. Coherence checking and PR reporting exist for `create_pr`, `review`, and
  `lid_planning` runs. Incremental `@spec` maturation remains the intended posture.
  External-agent discovery is now shipped through the authenticated interop API and MCP
  `get_project` surface: callers can discover the effective `lid_mode`, inspect detection
  metadata, consume the rendered LID workflow contract, and see that `lid_planning` is
  supported while Planning-PR correction remains unsupported until #3199 lands.

## Problem Statement

Paid adopted LID for its *own* development in #3072 (vendored method reference in
`docs/lid/`, the `## LID` block in `CLAUDE.md`/`AGENTS.md`, `bin/coherence-check.mjs`,
and a seeded design tree under `docs/intent/`). That made LID available to the tools that
work *on Paid*. It did nothing for the projects Paid works *on*.

Paid orchestrates agents over downstream GitHub repositories. Some of those repositories
are themselves LID projects (they carry a `## LID` block, `docs/intent/`,
`docs/high-level-design.md`). When Paid runs an agent on such a project today, the agent is
blind to LID: it receives a generic implementation prompt, ignores the design tree, mutates
code without updating EARS specs, and never cites `@spec` IDs. The arrow of intent breaks
at the moment Paid touches the repo.

Four capabilities are missing:

1. **Honor LID on configured projects.** When a downstream project is LID-configured, Paid's
   agent runs must walk the arrow — read the HLD/LLD/EARS, update specs when intent
   changes, write tests first with `@spec`, and annotate code at behavior entry points.
2. **Elicit intent through issue enhancement.** Paid already has a synchronous
   human-in-the-loop step — issue enhancement asks clarifying questions and waits for
   answers. That is exactly where LID's intent-elicitation phases belong: ask
   intent-focused questions, capture the answers as intent, and (for LID projects)
   materialize them into LLD/EARS during implementation. Not every project uses enhancement,
   so this is a layer *on top of* the others, not a dependency.
3. **Let a user request LID adoption.** A project owner should be able to ask Paid to
   bootstrap LID on a project that does not yet have it, using LID's brownfield analysis to
   reverse-engineer the existing code and plan docs into a design tree.
4. **Convert plan docs into LID artifacts.** Paid should turn existing RDRs, ADRs, design
   docs, and READMEs into HLD/LLD/EARS — authored intent, not inferred — as a special case
   of brownfield analysis weighted toward the plan-doc sources.

A fifth concern runs across all of them: once a design tree exists, the **existing code must
be linked to it** via `@spec` annotations. Brownfield conversion produces specs but does not,
by itself, annotate the code that already implements them — that linking has to happen
somehow, and this RDR states how.

Underlying all of this is a single reconciliation problem: **LID is a human-in-the-loop,
design-before-code process with mandatory phase-boundary stops; Paid's issue→PR flow is
built to run autonomously.** This RDR designs how those two models meet — and shows that
issue enhancement, where it is enabled, is the place the stops land most naturally.

## Context

### What LID is (in this repo)

LID (Linked-Intent Development) keeps intent and code coherent by flowing intent one
direction — `HLD → LLDs → EARS → Tests → Code` — and pausing for user review at every phase
boundary. The method is vendored under `docs/lid/`:

- `workflow.md` — the six-phase workflow (HLD check → LLD → EARS → intent-narrowing edge
  audit → tests-first → code) with a mandatory **STOP for user review** after each phase.
- `hld-template.md`, `lld-templates.md`, `ears-syntax.md`, `decision-doc-template.md` — the
  authoring templates.
- `audit-checklist.md` — the five coherence/audit checks (reference coherence, coverage,
  staleness, drift signals, orphan artifacts).
- `bin/coherence-check.mjs` — the runnable deterministic checker.

LID's brownfield posture (relevant to capabilities 2 and 3) is that reverse-engineered
LLDs use the **same template** as greenfield ones; what varies is the content's starting
state: Decisions & Alternatives entries carry `[inferred]` in the rationale column when the
decision was observed in code rather than authored, and the user confirms or refutes each
inference (removing the marker as they do). The LLD matures in place under normal cascade
discipline.

### Paid's run model today

- **Agent run goals** (`AgentRun::GOALS`): `create_pr`, `create_issue`, `review`,
  `enhance_issue`, `analyze_issue`. `AgentRun#prompt_for_goal` selects the prompt builder
  per goal. A new goal is the natural extension point for LID-specific runs.
- **Prompt building**: `Prompts::BuildForIssue` / `Prompts::BuildForPr` render DB-stored
  templates (`Prompts::Render`, slug + `fallback`), then append dynamic sections.
  `StyleGuides::InjectIntoPrompt` and `ProjectConventions::InjectIntoPrompt` compose
  project-specific guidance onto the final prompt. This is where a LID-aware section hooks
  in.
- **The repo is cloned into the container.** A downstream project's `docs/intent/`,
  `AGENTS.md`/`CLAUDE.md`, and tests are already present in the workspace — the agent can
  read and edit them without Paid injecting them.
- **Agent-image tooling** is installed per-run: `Containers::TokenOptimization` installs
  `rtk` and `codegraph` inside an already-started container. Vendoring the LID method
  reference + coherence checker into the agent image follows the same pattern.
- **Issue enhancement** (`enhance_issue` goal, `EnhanceIssueActivity`): a synchronous
  human-in-the-loop step. Paid builds a knowledge context, calls an LLM
  (`EnhanceIssueActivity#prompt_for`), and either marks the issue actionable or posts
  clarifying questions in a `<!-- paid:enhance-issue -->` comment and moves the issue to
  `paid_state: "needs_input"`. The LLM prompt is the exact extension point for
  intent-focused questioning. Enhancement is optional per project — not every project uses
  it — so LID must work without it (the bootstrap and implementation paths stand alone).
- **Needs-input flow** (the check-in channel enhancement rides on): an issue in
  `paid_state: "needs_input"` with a `paid-needs-input` label is surfaced by
  `Dashboard::NeedsInputQueue`; `ClarifyingQuestions::Load` /
  `ClarifyingQuestions::SubmitAnswers` / `ClarifyingQuestions::ClearNeedsInput` carry the
  questions and answers, and clearing the label re-enables the issue. This channel is
  **issue-only today** (the queue filters `is_pull_request: false`; the controller scopes to
  `issues_only`) — which makes it the right surface for *enhancement-driven* elicitation
  (issue-based) but the wrong one for confirming a *Planning PR* (which is why bootstrap
  confirmation uses PR review instead — see Decision Rationale).
- **PR review loop**: when a PR receives review, a `review`-goal run is triggered to address
  feedback. The PR is Paid's existing human gate for autonomous runs — and, for Planning PRs,
  the confirmation surface.

### Technical environment

- **Detection source of truth**: LID is declared in the *project's own* instruction file
  (`AGENTS.md`, or `CLAUDE.md` with `AGENTS.md` as a symlink) under a `## LID` block
  (`- Mode: Full|Scoped`, `- Version:`). The design tree lives at `docs/intent/`,
  `docs/high-level-design.md`, and optionally `docs/arrows/index.yaml`. These are the
  detection signals — they live in the repo, not in Paid.
- **Knowledge base** (`KnowledgeArtifact`, `KnowledgeChunk`, `Knowledge::Search`,
  `Knowledge::ContextBundle::Build`): could index LID artifacts for retrieval, but LID's
  source of truth is the repo's `docs/intent/`, so Paid should not duplicate the artifacts
  into its own DB (see Alternatives Considered).

## Research Findings

### Investigation process

1. Walked the vendored LID method (`docs/lid/`) end to end — workflow, brownfield posture,
   audit checklist, coherence checker, templates.
2. Traced Paid's prompt-building and agent-run-goal machinery to locate the exact extension
   points (`prompt_for_goal`, `BuildForIssue`, `*::InjectIntoPrompt`, `AgentRun::GOALS`).
3. Traced the needs-input / clarifying-questions flow, the issue-enhancement step, and the
   PR review loop to determine which surface carries intent elicitation vs. confirmation at
   each point (enhancement uses needs-input; Planning-PR confirmation uses PR review — see
   Decision Rationale).
4. Mapped LID's mandatory phase-boundary stops onto Paid's run model and found that
   enhancement — where enabled — absorbs the stops most naturally (below).
5. Mapped RDR/plan-doc sections onto LID artifacts to validate that conversion is a flavor
   of brownfield analysis rather than a separate pipeline.

### Key discoveries

**The tension is real, but enhancement resolves most of it.** LID's workflow states that
every phase boundary is a mandatory stop for user review. A single autonomous `create_pr`
run cannot pause mid-execution. But Paid *already* has a synchronous human-in-the-loop step
— issue enhancement — that asks questions and waits. Where enhancement is enabled, LID's
intent-elicitation phases (HLD check → LLD → EARS → edge audit) land there, *before*
implementation, with real human stops. The reconciliations, per path:

| Path | LID stops reconciled by… | Why |
|---|---|---|
| Implementation with enhancement (LID project) | **Enhancement** (intent elicitation, real stops) + **PR review** (backstop) | Enhancement asks intent-focused questions and waits for answers (Phases 1–4); `create_pr` then runs with confirmed intent (Phases 5–6). The PR catches implementation drift. The cleanest mapping — the stops are genuine, not faked. |
| Implementation without enhancement (LID project) | The **PR review cycle** | No pre-implementation human channel exists, so the run walks the arrow internally and self-reports phase state in the PR; the human reconciles at review. |
| Bootstrap / brownfield / conversion | A **docs-only Planning PR** reviewed via the **changes-requested flow** | The output is LID artifacts with `[inferred]` markers inline in the diff; the markers are the questions, and request-changes is the correction. The stops are real and synchronous. |

Enhancement is a layer on top of the others, not a dependency: bootstrap and the
no-enhancement implementation path work standalone, because not every project uses
enhancement.

**LID detection is a read of the repo, not a Paid setting.** Because LID is declared in the
project's instruction file, Paid detects it by reading that file plus the design-tree
presence. Per the *data over configuration* tenet, the detected mode is stored as data on
the project (overridable), not hardcoded.

**Conversion is brownfield analysis weighted toward authored sources.** A plan doc (RDR,
ADR, design doc) carries authored intent that maps directly onto LID artifacts without
`[inferred]` markers:

| Plan-doc section | LID artifact |
|---|---|
| Problem Statement | HLD `## Problem`; LLD context |
| Proposed Solution / Approach | LLD `## Approach` / `## System Design` |
| Alternatives Considered (with rationale) | LLD Decisions & Alternatives — **authored** rationale |
| Validation / acceptance criteria | EARS specs (testable claims) |
| Implementation Plan | Cascade ordering, segment boundaries |

Code-only reverse-engineering produces `[inferred]` markers; plan-doc-driven conversion
produces authored rationale. Both run the same brownfield procedure — the difference is the
input weighting, not the pipeline.

**"LID's brownfield analysis tools" are the workflow + the coherence checker, not a separate
binary.** There is no standalone `lid-brownfield` command. The tools are: the brownfield LLD
authoring process (`workflow.md` § Brownfield LLD content), the five audit checks
(`audit-checklist.md`), and `bin/coherence-check.mjs`. For a `lid_planning` run to use them
on a downstream project that does not vendor them, the agent image must carry the method
reference + checker (same pattern as `rtk`/`codegraph` today).

**Intent-eliciting questions are good practice regardless of LID.** The questions that
narrow an underspecified issue — what problem, what desired behavior (when X, the system
should Y), what constraints, what alternatives were rejected, what is in/out of scope, how
we know it's done — are the same questions LID's phases ask. They improve *any*
implementation, whether or not the answers become formal HLD/LLD/EARS. So the question
*style* should graduate from "LID-specific" to the default for all enhancement, phrased in
plain language with no LID jargon. What stays LID-specific is the *materialization*: only
LID projects turn the answers into artifacts during `create_pr`.

**Brownfield conversion leaves the code untagged.** Bootstrap/conversion produces HLD/LLD/
EARS, but the *existing* code and tests do not yet carry `@spec` annotations pointing at the
new specs. LID's coherence checks expect that linkage (coverage: every behavioral spec has
a citing test; drift: code/tests without `@spec` are flagged). So the linking has to happen
— and the cheapest answer is that it happens incrementally: as `create_pr` runs touch each
area under the LID-aware prompt, they add `@spec` at behavior entry points, and the tree
matures in place under normal cascade discipline (the same posture LID takes for
reverse-engineered LLDs). An optional dedicated tagging pass is a future enhancement, not a
prerequisite.

## Proposed Solution

### Approach

Four capabilities on three execution paths, all reusing existing infrastructure:

1. **Detection** — Paid reads the downstream repo on import/sync and records its LID mode.
2. **LID-aware issue enhancement** (the intent-elicitation entry point) — enhancement asks
   intent-focused questions in plain language (universal; no LID jargon); for LID projects
   the answers are captured as intent and materialized into LLD/EARS during `create_pr`.
   This is a layer on top of the others — it works only where enhancement is enabled, so the
   remaining paths stand alone.
3. **LID-aware implementation runs** — when a project is LID-configured, `create_pr` runs
   get a LID-aware prompt section (walk the arrow, update specs, tests-first, `@spec`). With
   enhancement the intent is pre-confirmed; without it, the PR review cycle is the gate.
4. **LID bootstrap + plan-doc conversion** — a new `lid_planning` goal runs brownfield
   analysis and opens a docs-only **Planning PR** whose inline `[inferred]` markers are
   confirmed or corrected through the PR review (request-changes) flow before any code
   lands. Independent of enhancement.

A cross-cutting concern — **`@spec` tagging of existing code** — matures incrementally as
implementation runs touch each area (§6 below).

### Technical design

#### 1. Detection — `projects.lid_mode`

Add a detected, overridable LID mode to the project:

```
projects
  lid_mode            string    -- nil | "full" | "scoped"
  lid_detection       jsonb     -- { "version": "1.3.0", "detected_at": ...,
                                  --    "sources": ["AGENTS.md ## LID block",
                                  --                 "docs/intent/", ...] }
```

`nil` means "not configured" (the default). Detection runs during repo import and on
sync (the instruction file and design tree can change). It checks, in order:

1. The `## LID` block in `AGENTS.md` (canonical; `CLAUDE.md` is the file under Claude
   Code). Parse `- Mode:` (default Full if block present but bullet missing/malformed —
   surface a one-line warning) and `- Version:`.
2. Presence of LID-shaped artifacts: `docs/intent/` content, `docs/high-level-design.md`,
   `docs/arrows/index.yaml`.

A project owner can override `lid_mode` (force on, force off, or re-run detection) from the
project settings — consistent with `ProjectConventions`' detect-then-override model. This is
**not** a Paid-side copy of the design tree; the repo remains the single source of truth.

#### 2. LID-aware issue enhancement (capability 2 — intent elicitation)

Enhancement is where LID's intent-elicitation phases land most naturally, because it is
already a synchronous human-in-the-loop step. The change is to the **enhancement prompt**
(`EnhanceIssueActivity#prompt_for`), not a new goal:

- **Universal question style.** Enhancement asks intent-focused questions in plain language,
  with no LID jargon, for *every* project: what problem; what the desired behavior is (phrased
  as "when X, the system should Y"); what constraints apply; what alternatives were
  considered or rejected; what is in/out of scope; how we know it's done. These are the
  questions LID's phases ask, and they improve any implementation.
- **LID-only materialization.** For a LID-configured project, the captured answers are passed
  to the subsequent `create_pr` run as **elicited intent**, which materializes them into the
  segment's LLD/EARS (see §3). For a non-LID project, the answers only inform implementation
  (and may feed `ChangeIntent` records per RDR-042 or knowledge artifacts).
- **Same machinery.** Questions still post through the `<!-- paid:enhance-issue -->` comment
  and ride the existing needs-input / clarifying-questions flow (`paid_state: "needs_input"` →
  `Dashboard::NeedsInputQueue` → `ClarifyingQuestions::*`). No new issue state or surface.

This is a layer on top of the bootstrap and implementation paths: where enhancement is
enabled, it pre-confirms intent so `create_pr` runs against settled intent; where it is not,
the other paths work unchanged.

#### 3. LID-aware implementation runs (capability 1)

When `project.lid_mode` is present and the run goal is `create_pr`, a new
`Lid::InjectIntoPrompt` service (sibling to `ProjectConventions::InjectIntoPrompt`) appends a
**LID-aware section** to the prompt built by `Prompts::BuildForIssue`. The section instructs
the agent to:

- Read `docs/high-level-design.md` and the relevant LLD(s) under `docs/intent/` for the area
  the issue touches; read the cited EARS specs.
- **Walk the arrow**: run a coherence pre-flight (do the EARS trace to the LLD, the LLD to
  the HLD?); if intent changed, update the spec/LLD *first*, then cascade down.
- **Tests first** with `@spec` annotations citing the EARS IDs; then code with `@spec` at
  the behavior's implementation-graph entry point.
- Run `bin/coherence-check.mjs` (available in the agent image — see below) for the
  structural checks before completing; treat failures as soft-blocks (fix forward, never
  `--no-verify`).
- Honor the mode: Full applies broadly; Scoped additionally checks a `## LID Scope`
  include/exclude section in the instruction file and only walks the arrow for in-scope
  paths.

The agent self-reports its phase progress (which specs it touched, tests-first evidence,
coherence-check result) in the PR description. **The PR review cycle is the human gate** —
this is the honest mapping of LID's mandatory stops onto an autonomous run. A reviewer
requesting changes is exactly a phase-boundary reconciliation; the `review`-goal follow-up
run addresses it under the same LID-aware prompt.

Where enhancement ran first (§2), the `create_pr` run consumes the **elicited intent** —
the captured answers — and uses them to draft or update the segment's LLD/EARS before
implementing, so intent is pre-confirmed rather than guessed. Where enhancement did not run,
the agent derives intent from the issue body and the existing tree, and the PR is the sole
reconciliation point.

The LID-aware section is **additive** — it layers onto the existing prompt, so style guides,
conventions, and the service-environment sections are unaffected. For `review`-goal runs on
a LID project, `Prompts::BuildForPr` includes the same section so PR-continuation work also
walks the arrow.

#### 4. Bootstrap + conversion via a `lid_planning` goal (capabilities 3 & 4)

A new agent run goal `lid_planning` produces **docs-only** LID artifacts and opens a
Planning PR. It is triggered two ways:

- **Adoption**: a "Start using LID" action on the project (UI toggle / labeled issue). Paid
  bootstraps the design tree onto a project that does not yet have one.
- **Conversion**: the user points Paid at existing plan docs (RDRs, ADRs, design docs,
  README) to convert into LID artifacts. The run weights its analysis toward those authored
  sources.

The `lid_planning` run:

1. Reads the repo — code *and* any named plan docs — using the brownfield procedure from
   `workflow.md` § Brownfield LLD content and the five audit checks.
2. Produces LID artifacts as **docs-only changes** (no code):
   - Seeds or updates `docs/high-level-design.md` (Problem, Approach, Tenets, System
     Design) from the project description + plan docs.
   - Creates `docs/intent/<segment>/` LLDs. Decisions reverse-engineered from code carry
     `[inferred]`; decisions sourced from plan docs carry authored rationale.
   - Derives EARS specs (one testable claim per line, `[x]`/`[ ]`/`[D]` markers) from
     described and observed behavior.
   - On adoption, adds the `## LID` block (`- Mode:`, `- Version:`) to `AGENTS.md` and
     creates `docs/arrows/index.yaml`.
3. Opens a **Planning PR** containing only `docs/` and instruction-file changes. The PR
   description carries a **"Confirm these inferred decisions" checklist** — a short list of
   the load-bearing `[inferred]` items and any genuine open questions from the edge audit,
   so the reviewer knows exactly what to look at.

Because the output is pure intent, LID's phase-boundary stops are honored **synchronously**:
nothing lands until the human reviews.

#### 5. Intent confirmation via the PR review flow

This is the "check in with the user about whether Paid got the intent correct" loop. It uses
**one surface — the Planning PR** — and reuses the existing PR review machinery, including
the `review`-goal run that already acts on review feedback.

The `[inferred]` markers are **inline in the diff**, situated in their full LLD context, so
they *are* the questions — no abstraction into a separate Q&A form. The reviewer reconciles
intent through normal review actions:

- **Approve / merge** = confirm. The accepted inferences stand; their `[inferred]` markers
  mature out over time under normal cascade discipline (or a later pass strips them and
  writes the rationale as authored).
- **Request changes** + an inline comment on a `[inferred]` line = correct that decision.
  The `review`-goal run (already wired for PR-continuation) reads the inline comment,
  revises the affected LLD/EARS on the Planning PR, and replaces the `[inferred]` marker with
  the user's authored rationale.
- **Comment-only** (no changes requested) = defer. The item stays `[inferred]` or moves to
  the LLD's Open Questions; it is re-audited later, not blocking the merge.

Because correction rides on the `review` goal, the loop needs no new human-facing surface
and no new issue state: the Planning PR is the artifact, the question, and the
confirmation channel at once. This is LID's "STOP for user review" realized through Paid's
native PR review gate.

#### 6. `@spec` tagging of existing code (cross-cutting)

Bootstrap/conversion (§4) creates HLD/LLD/EARS, but the *existing* code and tests do not yet
carry `@spec` annotations pointing at the new specs — LID's coherence checks expect that
linkage (coverage: every behavioral spec has a citing test; drift: unlinked code/tests are
flagged). The design for closing that gap, in order of preference:

- **Incremental (default).** Do not tag retroactively as a discrete step. As `create_pr`
  runs touch each area under the LID-aware prompt (§3), they add `@spec` at behavior entry
  points, and the tree matures in place under normal cascade discipline — the same posture
  LID takes for reverse-engineered LLDs. This is the cheapest path and avoids a large,
  speculative code-only PR.
- **Optional dedicated tagging pass (future).** A run that walks existing code and adds
  `@spec` annotations for the newly-created specs, prioritized by hotspot / changefrequency.
  This is a code PR (not docs-only), distinct from the bootstrap Planning PR. Deferred until
  incremental maturation proves too slow for a given project; not a prerequisite for LID to
  function.

The coherence checker flags the gap honestly — unlinked code/tests surface as drift
signals — so the maturation progress is visible without blocking.

#### 7. Vendoring the LID method into the agent image

`lid_planning` runs (and the coherence check in LID-aware implementation runs) need the LID
method reference and `bin/coherence-check.mjs` available in the container, because a
downstream project being bootstrapped will not have them. Following the `rtk`/`codegraph`
install pattern (`Containers::TokenOptimization`), the agent image
(`docker/agent/Dockerfile`) vendors `docs/lid/` and `bin/coherence-check.mjs` so any run can
invoke the procedure. A LID-aware implementation run on a project that *already* vendors its
own checker uses the project's; the image copy is the fallback.

### Decision rationale

1. **Prompt-side + PR gate for implementation** (over orchestration-phased multi-run). A
   LID-aware prompt section is additive and reuses `BuildForIssue`, `*::InjectIntoPrompt`,
   and the entire PR review loop. An orchestration-phased design would add Temporal workflow
   states, gates, and resumption to express stops as true mid-run gates — heavy machinery
   for a stop that, in an autonomous run, can only ever resolve at the PR anyway. The PR is
   *already* the human reconciliation point; making it carry LID's stops costs nothing new.
   (Settled direction per the planning conversation.)

2. **Planning PR + PR review for confirmation** (over interactive chat, over the needs-input
   Q&A channel, over a new confirmation surface). A docs-only PR is the natural carrier for
   LID artifacts: it is reviewable, diffable, and merges through the same gate as any change.
   Because the `[inferred]` markers sit inline in the diff, the PR review *is* the
   confirmation — request-changes + an inline comment corrects a specific inference; approve
   confirms. This reuses the entire PR review loop and the `review`-goal run that already
   acts on review feedback, with **no new human-facing surface and no second surface to
   context-switch between**. The needs-input/clarifying-questions channel was considered and
   rejected: it is issue-only today (the queue excludes PRs), and abstracting inline
   `[inferred]` decisions into a separate issue Q&A would split the artifact from its
   confirmation and lose the diff context. Interactive chat was rejected for the same
   reason — it adds a conversational flow without a reviewable artifact. (Settled direction
   per the planning conversation.)

3. **The repo is the single source of truth** (over mirroring LID artifacts into Paid's DB).
   LID's premise is that intent lives in `docs/intent/` and travels with the repo. Duplicating
   HLD/LLD/EARS into Paid tables would create a second source that drifts. Paid stores only
   `lid_mode` + detection metadata — enough to vary the prompt — and treats the repo's tree
   as authoritative.

4. **A new `lid_planning` goal** (over overloading `enhance_issue`/`analyze_issue`). The
   output shape (docs-only LID artifacts), the prompt (the brownfield procedure), and the
   completion semantics (open a docs-only Planning PR for review) are distinct from the
   existing goals. A dedicated goal keeps `prompt_for_goal` switching clean and lets
   `default_agent_runners_by_goal` route it independently.

5. **Conversion is a `lid_planning` run variant, not a separate pipeline.** Plan docs and
   code are both inputs to the same brownfield procedure; the only difference is input
   weighting and whether decisions land authored or `[inferred]`. One goal, one prompt
   family, parameterized by the named plan-doc sources.

6. **Enhancement carries intent elicitation; the question style is universal.** Enhancement
   is already a synchronous human-in-the-loop step, so it is where LID's intent phases belong
   — and where they land as *real* stops rather than PR-adjacent reconciliations. The
   intent-focused question style (problem, desired behavior, constraints, rejected
   alternatives, scope, done-ness) is adopted for *all* enhancement in plain language, because
   it improves any implementation; only the materialization into LLD/EARS is gated on
   `lid_mode`. Enhancement is a layer, not a dependency — bootstrap and the no-enhancement
   implementation path work standalone, since not every project uses enhancement. (Settled
   direction per the planning conversation.)

7. **`@spec` tagging matures incrementally** (over a mandatory retroactive tagging pass).
   Brownfield conversion produces specs but cannot, in the same docs-only PR, annotate all
   existing code that implements them. Forcing a large speculative code PR works against
   LID's "matures in place" posture. Incremental tagging as `create_pr` runs touch each area,
   with the coherence checker surfacing the gap honestly, is the cheaper and more honest
   path; a dedicated tagging pass remains an optional future enhancement.

### Implementation example

```text
# Adoption request — user clicks "Start using LID" on project "acme/api"
# Paid creates an issue (goal: lid_planning) and queues a run.

# The lid_planning run, in the container:
#   - reads app/**, db/schema.rb, the existing README and 3 ADRs
#   - runs the brownfield procedure (workflow.md § Brownfield LLD content)
#   - produces docs-only changes:
#       docs/high-level-design.md          (seeded)
#       docs/intent/README.md
#       docs/intent/auth/auth-design.md    (LLD; [inferred] on 2 decisions
#                                          reverse-engineered from code)
#       docs/intent/auth/auth-specs.md     (EARS)
#       docs/intent/billing/...            (LLD; authored rationale from an ADR)
#       docs/arrows/index.yaml
#       AGENTS.md                          (+ ## LID block: Mode Full, Version 1.3.0)
#   - opens Planning PR #42 "docs: bootstrap LID design tree"
#     description: "Confirm these inferred decisions:" + checklist of the 2
#     load-bearing [inferred] items (auth strategy, billing idempotency)

# User reviews PR #42:
#   - billing idempotency [inferred] line: requests changes + inline comment
#     "Wrong — we key on idempotency headers, fix it."
#   - auth strategy [inferred] line: left as-is (implicitly confirmed)

# The review-goal run reads the inline comment, revises the billing LLD on
# PR #42 per the correction, and replaces that [inferred] marker with the
# user's authored rationale.
# User approves + merges PR #42. projects.lid_mode is now "full" (re-detected on merge).
# Future create_pr runs on acme/api get the LID-aware prompt section.
```

## Alternatives Considered

### Alternative 1: Orchestration-phased multi-run with true mid-run gates

**Description**: Model LID's six phases as Temporal workflow states. A planning activity
produces LID artifacts and the workflow suspends on a signal; a human approves via a Paid
gate; implementation activities run under the same gate per phase.

**Pros**:

- Stops become true gates, not PR-adjacent reconciliations.
- Phase state is durable and resumable.

**Cons**:

- Heavy: new workflow states, signals, gates, resumption, and timeout handling for a stop
  that, in an autonomous run, resolves at the PR regardless.
- Duplicates the human-reconciliation channel that the PR review loop already provides.
- LID's own carveout notes a directed audit pass is not phase-structured; forcing every
  change through six gated workflow states fights Paid's focused-run model (RDR-031).

**Reason for rejection**: The prompt-side + PR-gate design achieves the same human
reconciliation at a fraction of the orchestration cost. Rejected per the settled direction.

### Alternative 2: Interactive chat for intent confirmation

**Description**: Open a `ChatSession` that walks each inferred decision with
approve/edit/reject, mirroring the write-tool confirmation pattern.

**Pros**:

- Conversational; lower friction per decision.
- Reuses the chat MCP tool-dispatch and human-in-the-loop approval.

**Cons**:

- Does not produce a reviewable artifact by default — the LID tree *is* the artifact and
  wants diff/merge semantics, not a transcript.
- Adds a parallel confirmation surface alongside the PR review loop.
- Chat sessions are archived/expired; intent confirmation wants a durable, mergeable PR.

**Reason for rejection**: Confirmation belongs on the Planning PR, where the `[inferred]`
markers already sit inline. A chat session separates the conversation from the artifact it's
about. Rejected per the settled direction.

### Alternative 3: Needs-input / clarifying-questions Q&A on the source issue

**Description**: After opening the Planning PR, move the source issue to `paid_state:
"needs_input"` and surface each load-bearing `[inferred]` decision as a structured
clarifying question (reusing `Dashboard::NeedsInputQueue` + `ClarifyingQuestions::*`); the
user answers on the issue, and a follow-up run revises the PR.

**Pros**:

- Reuses an existing, purpose-built "the agent needs the human before proceeding" channel
  verbatim.
- Proactive surfacing via the Needs Input queue dashboard.

**Cons**:

- **Split surface**: the artifacts live on the PR, the questions on the issue. The user must
  read the diff, then context-switch to an issue form to answer — losing the inline context
  that makes a `[inferred]` decision evaluable.
- The channel is issue-only today (`NeedsInputQueue` filters `is_pull_request: false`;
  `ClarifyingQuestionsController` scopes to `issues_only`), so the PR cannot itself carry the
  questions without new machinery.
- Abstracts inline decisions into a parallel Q&A list, duplicating what PR review comments
  already express natively.

**Reason for rejection**: The `[inferred]` markers are already inline in the PR diff; the
review comment on that line *is* the correction. Routing the same confirmation through a
separate issue Q&A adds a surface and loses context for no gain. PR review (request-changes)
is the cleaner confirmation channel.

### Alternative 4: Mirror LID artifacts into Paid's database

**Description**: Parse the downstream `docs/intent/` into Paid-side tables (e.g., a
`lid_segment` model) so Paid can query specs, drive coherence checks server-side, and index
them as knowledge artifacts.

**Pros**:

- Server-side coherence checks and knowledge-base retrieval of specs.
- Paid could enforce `@spec` coverage without relying on the in-container checker.

**Cons**:

- Violates LID's core premise: the repo's `docs/intent/` is the source of truth. A Paid-side
  mirror drifts the moment a human edits the repo outside Paid.
- Duplicates the arrow; two sources of intent invite incoherence — the exact failure LID
  exists to prevent.
- High maintenance cost for marginal benefit; the agent already has the repo in-container.

**Reason for rejection**: The repo is authoritative. Paid stores only `lid_mode` +
detection metadata and reads the tree at run time. (Knowledge-base indexing of LID
artifacts remains a possible *future* enhancement, read-only and clearly derived, but is
out of scope here.)

### Alternative 5: A standalone "brownfield analysis" tool/binary

**Description**: Build or vendor a dedicated `lid-brownfield` CLI that produces LID
artifacts from a repo, distinct from the workflow + coherence checker.

**Pros**:

- Single command for bootstrap/conversion.

**Cons**:

- No such tool exists in LID; the brownfield procedure *is* the workflow plus the audit
  checks plus `[inferred]` authoring. Inventing a binary duplicates the method.
- The procedure requires judgment (segment boundaries, tenet elicitation, edge audit) that
  belongs in the agent prompt, not a deterministic CLI.

**Reason for rejection**: The brownfield "tools" are the vendored workflow + coherence
checker, carried in the agent image. The `lid_planning` prompt encodes the procedure.

## Trade-offs and Consequences

### Positive consequences

- **Paid stops breaking the arrow on LID projects.** Implementation runs read and update the
  design tree; specs and `@spec` annotations stay coherent.
- **Intent gets elicited before code, where enhancement runs.** Underspecified issues are
  narrowed through intent-focused questions *before* implementation — LID's stops landing as
  real human-in-the-loop checkpoints, not faked at the PR.
- **Better questions for everyone.** The intent-elicitation question style improves
  enhancement on non-LID projects too, since it is just good engineering questioning in plain
  language.
- **Adoption is one action away.** A project owner can bootstrap LID without leaving Paid,
  using the same brownfield procedure a human would, with Paid doing the
  reverse-engineering heavy lifting.
- **Plan docs become living intent.** RDRs/ADRs convert into walkable HLD/LLD/EARS instead
  of rotting as prose.
- **Reuses existing infrastructure end to end** — prompt injection, agent-run goals,
  enhancement + needs-input, and the PR review loop (both as the implementation-run gate and
  as the Planning-PR confirmation surface). No new human-facing surface.
- **Repo stays the source of truth.** No drift between Paid and the project's own intent.

### Negative consequences

- **Implementation runs can't truly pause per phase** (without enhancement). A single
  autonomous run walks the arrow internally and reconciles at the PR. Where enhancement runs
  first this is resolved — intent is settled before code — but on projects without
  enhancement it remains an honest tradeoff, surfaced in the PR description.
- **Brownfield conversion leaves existing code untagged.** Specs appear without matching
  `@spec` annotations until incremental runs catch up; the gap is surfaced (not hidden) by
  the coherence checker.
- **More prompt surface to maintain.** A LID-aware section and a `lid_planning` prompt
  family join the prompt-evolution pipeline (RDR-009), with their own versioning and
  metrics.
- **Agent-image coupling.** Vendoring `docs/lid/` + the checker into the agent image means a
  LID method bump touches the image (mirrors the existing `rtk`/`codegraph` coupling).
- **Detection can lag.** `lid_mode` is detected on import/sync; a repo that adds LID between
  syncs is mis-detected until the next sync (mitigated: manual re-detect from project
  settings).

### Risks and mitigations

- **Risk**: The agent does not faithfully walk the arrow despite the prompt.
  **Mitigation**: The LID-aware section names the concrete steps; `bin/coherence-check.mjs`
  is a structural soft-block run before completion; the PR description self-report lets a
  reviewer catch a skipped arrow walk. The user-is-always-right override still holds (LID is
  not a CI gate), but the cost is made visible.

- **Risk**: Brownfield `[inferred]` intent is wrong and ships unconfirmed.
  **Mitigation**: The Planning PR is docs-only and reviewable line-by-line; the load-bearing
  `[inferred]` items are called out in the PR description's checklist; corrections land via
  the `review`-goal run before merge.

- **Risk**: A large bootstrap produces many `[inferred]` markers, overwhelming review.
  **Mitigation**: Only *load-bearing* inferences and genuine ambiguities are called out in
  the checklist (the earns-its-place heuristic); routine inferences stay `[inferred]` and
  mature in place under normal cascade discipline without blocking the review.

- **Risk**: Scoped-LID misconfiguration (missing `## LID Scope`) silently widens scope.
  **Mitigation**: Fall back to treating all prompts as in-scope and surface a warning — the
  same behavior LID's own mode-aware triggering specifies.

- **Risk**: Conversion produces specs that don't match existing tests, creating reverse
  orphans (`@spec` citing absent IDs).
  **Mitigation**: The coherence checker flags reverse orphans as asks; the follow-up
  revision run resolves them (create the spec, delete the annotation, or alias) per the
  audit checklist's "do not auto-resolve" rule.

## Implementation Plan

### Phase 0: Detection + data model

**Prerequisites:**

- [x] Repo import/sync path identified (where the instruction file is already read)

**Step 1**: [x] `rails generate migration AddLidModeToProjects` — add `lid_mode` (string) and
`lid_detection` (jsonb) to `projects` with comments.

**Step 2**: [x] `Projects::DetectLidMode` service — parse the `## LID` block from the repo's
`AGENTS.md`/`CLAUDE.md` and check for `docs/intent/`, `docs/high-level-design.md`,
`docs/arrows/index.yaml`. Wire into import and sync.

**Step 3**: [x] Project-settings UI to view/override `lid_mode` and trigger re-detection.

**Files to create/modify:**

- `db/migrate/TIMESTAMP_add_lid_mode_to_projects.rb`
- `app/services/projects/detect_lid_mode.rb`
- `app/models/project.rb` (associations/accessors)
- import + sync call sites

### Phase 1: LID-aware implementation runs (capability 1)

**Prerequisites:**

- [x] Phase 0 complete
- [x] Agent image vendors `docs/lid/` + `bin/coherence-check.mjs`

**Step 1**: [x] `Lid::InjectIntoPrompt` — appends the LID-aware section when
`project.lid_mode` is present. Compose into `Prompts::BuildForIssue` and
`Prompts::BuildForPr` alongside the existing `*::InjectIntoPrompt` calls.

**Step 2**: [x] Seed the LID-aware prompt section as a DB prompt fragment (RDR-009 pipeline)
with a fallback constant.

**Step 3**: [x] Agent-image change (`docker/agent/Dockerfile`) to vendor the method reference +
checker.

**Files to create/modify:**

- `app/services/lid/inject_into_prompt.rb`
- `app/services/prompts/build_for_issue.rb`, `app/services/prompts/build_for_pr.rb`
- `db/seeds/prompts.rb`
- `docker/agent/Dockerfile` (and the agent-image build chain)

### Phase 2: LID-aware issue enhancement (capability 2 — intent elicitation)

**Prerequisites:**

- [x] Phase 0 complete (enhancement's materialization branch keys off `lid_mode`)

**Step 1**: [x] Update the enhancement prompt (`EnhanceIssueActivity#prompt_for`, seeded as a DB
prompt) to ask intent-focused questions in plain language for *all* projects — problem,
desired behavior (when/then), constraints, rejected alternatives, scope, done-ness.

**Step 2**: [ ] For LID-configured projects, pass the captured clarifying-question answers
forward as **elicited intent** so the `create_pr` run (Phase 1) materializes them into the
segment's LLD/EARS. (The answers already persist in the issue via the existing
clarifying-questions flow; the create_pr prompt already consumes them, and the remaining
artifact-materialization work is tracked in #3200.)

**Files to create/modify:**

- `app/temporal/activities/enhance_issue_activity.rb` (`prompt_for` / seeded prompt)
- `db/seeds/prompts.rb` (intent-elicitation enhancement prompt)
- `app/services/prompts/build_for_issue.rb` (surface elicited intent to create_pr)

### Phase 3: `lid_planning` goal — brownfield analysis + Planning PR (capabilities 3 & 4)

**Prerequisites:**

- [x] Phase 0 complete

**Step 1**: [x] Add `"lid_planning"` to `AgentRun::GOALS`; add the predicate and the
`prompt_for_goal` branch.

**Step 2**: [x] `Prompts::BuildForLidPlanning` — encodes the brownfield procedure (read repo +
named plan docs; produce docs-only HLD/LLD/EARS with `[inferred]`/authored markers; add the
`## LID` block on adoption; create `docs/arrows/index.yaml`); instructs a docs-only PR.

**Step 3**: [x] Trigger surface — "Start using LID" project action (adoption) and a
plan-doc-source input (conversion). Both queue a `lid_planning` run. The output
contract is server-side enforced via `Lid::PlanningContract` (adoption vs
refinement artifact sets), and named plan docs carry authored-intent weighting
in the planning prompt.

**Files to create/modify:**

- `app/models/agent_run.rb` (`GOALS`, predicate, `prompt_for_goal`)
- `app/services/prompts/build_for_lid_planning.rb`
- `app/services/lid/planning_contract.rb`
- `db/seeds/prompts.rb`
- controller/view for the trigger (adoption + conversion)

### Phase 4: Intent confirmation via the PR review flow (confirmation loop)

**Prerequisites:**

- [x] Phase 3 foundation complete
- [x] `review`-goal runs can act on a Planning PR (docs-only diff handling exists; the
  dedicated correction loop remains open)

**Step 1**: [ ] On Planning-PR creation, build the "Confirm these inferred decisions" checklist
into the PR description from the load-bearing `[inferred]` markers and edge-audit gaps.
The current Planning-PR path appends a checklist by extracting it heuristically from the
agent summary; a dedicated checklist builder still belongs here.

**Step 2**: [ ] Wire the existing `review`-goal run to revise Planning PRs: when a reviewer
requests changes with an inline comment on a `[inferred]` line, the run applies the
correction to the LLD/EARS and replaces the marker with the user's authored rationale.
Tracked in #3199.

**Files to create/modify:**

- `app/services/lid/build_inference_checklist.rb` (derive the PR-description checklist)
- `lid_planning` completion path (open PR + post checklist)
- `review`-goal prompt/path (handle `[inferred]`-targeted change requests on Planning PRs)

### Phase 5: Conversion polish, coherence gating, and incremental tagging

**Prerequisites:**

- [ ] Phases 3 and 4 complete

**Step 1**: [x] Conversion-specific prompt weighting (favor named plan docs; map
problem/alternatives/validation → HLD/LLD/EARS as in the table above). Named plan
docs are treated as authored intent (no `[inferred]` marker); code-sourced
rationale remains `[inferred]`.

**Step 2**: [x] Run `bin/coherence-check.mjs` as a structural soft-block at the end of every
`lid_planning` and LID-aware run; surface failures in the PR description.

**Step 3 (incremental, no separate phase)**: [ ] `@spec` tagging matures as Phase 1
implementation runs touch each area (no retroactive tagging pass by default). The coherence
checker surfaces unlinked code/tests as drift signals so progress is visible. A dedicated
tagging pass remains a possible future enhancement, not built here.

### Dependencies

- Repo import/sync path (exists)
- Prompt-building + `*::InjectIntoPrompt` composition (exists)
- Agent run goal + `prompt_for_goal` switching (exists)
- Issue enhancement (`EnhanceIssueActivity`) + needs-input / clarifying-questions flow
  (exists; the intent-elicitation surface)
- PR review loop + `review`-goal run (exists; the confirmation surface for Planning PRs)
- Agent-image build chain (exists; modified to vendor LID method)

## Validation

### Testing approach

1. Unit tests for `Projects::DetectLidMode` (Full/Scoped/absent; malformed block; scope
   section missing).
2. Unit tests for `Lid::InjectIntoPrompt` (section appended only when `lid_mode` present;
   no-op otherwise; idempotent).
3. Unit tests for `Prompts::BuildForLidPlanning` (docs-only output; `[inferred]` on
   code-sourced decisions; authored rationale on plan-doc-sourced decisions).
4. Integration tests for the intent-confirmation loop: Planning PR with `[inferred]`
   markers → reviewer requests changes with an inline comment → `review`-goal run revises
   the artifact and replaces the marker → reviewer approves/merges.
5. Integration test: a `create_pr` run on a LID-configured project produces a prompt
   containing the LID-aware section and a PR description that self-reports phase state.
6. Unit/integration tests for LID-aware enhancement: the enhancement prompt asks
   intent-focused questions in plain language (all projects); captured answers are surfaced
   as elicited intent to `create_pr` when `lid_mode` is set, and materialized into LLD/EARS.

### Test scenarios

1. **Scenario**: Project with a `## LID` block (Mode: Full) is imported.
   **Expected**: `projects.lid_mode == "full"`; detection metadata records version +
   sources.

2. **Scenario**: `create_pr` run on a LID-configured project.
   **Expected**: prompt contains the LID-aware section; agent instructed to walk the arrow,
   tests-first, `@spec`, run coherence check.

3. **Scenario**: `lid_planning` adoption run on a non-LID project.
   **Expected**: docs-only PR with seeded HLD, LLD(s) with `[inferred]` markers, EARS,
   `docs/arrows/index.yaml`, and a new `## LID` block in `AGENTS.md`.

4. **Scenario**: Conversion run pointed at an RDR.
   **Expected**: LLD Decisions & Alternatives carry authored rationale (from the RDR's
   Alternatives Considered), not `[inferred]`; EARS derived from the RDR's validation
   criteria.

5. **Scenario**: Planning PR opened with a `[inferred]` marker; reviewer requests changes
   with an inline comment correcting it.
   **Expected**: the `review`-goal run revises the affected LLD/EARS on the PR and replaces
   the `[inferred]` marker with the user's authored rationale; the PR is then approvable.

6. **Scenario**: User overrides `lid_mode` to force off.
   **Expected**: `create_pr` runs get the plain prompt (no LID section) regardless of repo
   contents.

7. **Scenario**: Scoped-LID project with a missing `## LID Scope` section.
   **Expected**: warning surfaced; all prompts treated as in-scope.

8. **Scenario**: Underspecified issue on a LID project with enhancement enabled.
   **Expected**: enhancement asks intent-focused questions (plain language); issue goes to
   `needs_input`; user answers; the subsequent `create_pr` run materializes the answers into
   the segment's LLD/EARS and implements against confirmed intent.

9. **Scenario**: Same underspecified issue on a non-LID project.
   **Expected**: enhancement still asks the intent-focused questions (universal style); the
   answers inform implementation but produce no LID artifacts.

10. **Scenario**: LID project that does not use enhancement.
    **Expected**: bootstrap (Planning PR) and `create_pr` (LID-aware section) work standalone;
    the PR review cycle is the gate.

### Performance validation

- Detection adds one instruction-file read + a few path checks per sync — negligible.
- `Lid::InjectIntoPrompt` appends a static-ish section — sub-millisecond.
- `lid_planning` runs are agent-bound (LLM work), not infra-bound; coherence check is the
  existing Node script (seconds).

### Security validation

- `lid_mode` is project-scoped and tenant-filtered like other project attributes.
- The agent image's vendored method reference is read-only tooling (no secrets, no network).
- Review comments driving corrections are trusted-user input (the PR review path already
  gates on project collaborator/allowlist status, same as the live PR prompt builder).

## References

### Requirements & standards

- LID method reference — `docs/lid/` (`workflow.md`, `audit-checklist.md`,
  `hld-template.md`, `lld-templates.md`, `ears-syntax.md`, `decision-doc-template.md`)
- `bin/coherence-check.mjs` — deterministic coherence checker
- `docs/intent/README.md`, `docs/high-level-design.md`, `docs/arrows/` — Paid's own LID tree
- LID adoption PR #3072 — `feat(lid): adopt Linked-Intent Development across the toolchain`

### Dependencies

- `app/models/agent_run.rb` — `GOALS`, `prompt_for_goal`, goal predicates
- `app/services/prompts/build_for_issue.rb`, `build_for_pr.rb` — prompt composition +
  `*::InjectIntoPrompt` injection points
- `app/temporal/activities/enhance_issue_activity.rb` — `prompt_for`, the intent-elicitation
  extension point; `<!-- paid:enhance-issue -->` comment + needs-input flow
- `app/services/project_conventions/automation_profile.rb` — detect-then-override model to
  mirror for `lid_mode`
- `app/services/clarifying_questions/*.rb`, `app/services/dashboard/needs_input_queue.rb` —
  the issue-side check-in channel enhancement rides on (and that bootstrap confirmation does
  *not* use, since it is PR-based)
- `app/services/containers/token_optimization.rb` — agent-image tooling install pattern to
  mirror for the vendored LID method
- `docker/agent/Dockerfile` — agent image build

### Research resources

- LID brownfield posture: reverse-engineered LLDs use the same template; `[inferred]`
  markers on observed decisions, removed as the user confirms.
- LID mode-aware triggering: Full applies broadly; Scoped checks `## LID Scope`
  include/exclude globs; missing scope falls back to in-scope with a warning.
- LID coherence verification: structural checks (soft-block) + semantic checks (surfaced,
  non-blocking); the project's declared coherence script runs the structural checks.

## Notes

- **Knowledge-base indexing of LID artifacts** (read-only, clearly derived from the repo's
  `docs/intent/`) is a plausible future enhancement so `Knowledge::Search` and context
  bundles can surface specs to agents. It is explicitly *not* a second source of truth — it
  would be a re-indexed projection, invalidated on tree changes. Out of scope for this RDR.
- **`lid_planning` and enhancement are complementary, not competing.** Bootstrap
  (`lid_planning`) retroactively creates the tree from existing code/docs — one-time or
  occasional, works on any project. Enhancement elicits intent *per issue* and grows the
  tree going forward, but only where enhancement is enabled. They share the brownfield
  procedure and the `[inferred]`/authored distinction; they do not depend on each other.
- **Universal question style is the likely first win.** Because the intent-elicitation
  questions are plain-language good practice, adopting them for all enhancement (independent
  of `lid_mode`) can ship first and be evaluated before the LID-materialization branch.
- **Scoped-LID detection** of the `## LID Scope` section should feed the LID-aware prompt so
  the agent can skip the arrow for out-of-scope paths — a Phase 1+ refinement.
- **Re-detection on PR merge**: when a Planning PR merges the `## LID` block, the next sync
  re-detects `lid_mode` automatically; no manual flip required.
