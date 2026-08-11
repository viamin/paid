# RDR-053: New Feature Creation — RDR-Driven Issue Trees with LID Support

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-09
- **Status**: Implemented (2026-08-11)
- **Type**: Architecture + Process
- **Priority**: P1
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md) (Interactive Chat), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-031](RDR-031-focused-agent-runs.md) (Focused Agent Runs), [RDR-009](RDR-009-prompt-evolution.md) (Feature Creation vs Existing Goals), [RDR-044](RDR-044-configuration-profiles-chat.md) (Chat-Driven Configuration Profiles)
- **Related Issues**: #3305 (chat path), #3306 (run/needs-input path), #3307 (LID integration), #3308 (E2E tests + closeout)

## Problem Statement

Paid can implement features from well-specified issues, but it cannot *create* those specifications. Today, a user who wants to build a new feature must:

1. Manually write the issue (or RDR) themselves
2. Decide how to decompose it into implementable sub-issues
3. Manually create those issues with proper dependencies
4. (Optionally) manually bootstrap LID if they want intent tracking

There is no "start from a feature idea" entry point. The user is the bridge between "I want to build X" and "here are the issues Paid can pick up." This is the most labor-intensive, highest-leverage part of the development process, and it is exactly where an AI agent adds the most value: research, decomposition, and specification.

Three capabilities are missing:

1. **Feature specification via Q&A.** A user should be able to say "create a new feature: add dark mode" in chat or trigger a feature-creation run, and Paid should gather enough detail through intent-focused questions (problem, desired behavior, constraints, scope, done-ness) to write a complete specification — an RDR.
2. **RDR → issue tree decomposition.** Once the specification is settled, Paid should produce an RDR document in a PR and file a tree of linked issues (epic → phases → tasks) whose implementation plan traces back to the RDR's sections.
3. **LID integration.** If the project supports LID, the RDR should feed into LID artifacts (HLD/LLD/EARS) so the resulting issue tree is intent-tracked from day one. If the project does not yet support LID but the user wants it, the feature-creation flow should offer to bootstrap LID as a prerequisite.

A fourth concern runs across these: the Q&A must be **adaptive**, not a fixed questionnaire. The questions depend on the feature's domain, the project's architecture, and the answers already given. A generic checklist produces shallow specifications; the agent must read the codebase and ask targeted questions.

### Requirements

- **New agent run goal** `create_feature`, distinct from `create_issue` and `lid_planning`
- **Two entry points**: chat-initiated (synchronous Q&A → run trigger) and direct run trigger (UI/API → needs-input Q&A if detail is insufficient)
- **Output**: a docs-only PR containing the RDR markdown, followed by filed issues referencing the RDR
- **LID-aware**: if `project.lid_mode` is set, the RDR feeds into LID artifacts; if not set but the user opts in, bootstrap LID first via `lid_planning`
- **Intent-focused Q&A** in the same style as RDR-051's universal enhancement questions (problem, desired behavior, constraints, rejected alternatives, scope, done-ness)
- **Permission**: any user with access to a project can create an RDR for it (no granular gating until RBAC matures)

## Context

### What an RDR is (in Paid)

Per `docs/rdrs/README.md`, an RDR (Recommendation Decision Record) is a specification prompt built through iterative research and refinement. Key sections: Problem Statement, Context, Research Findings, Proposed Solution (with rationale), Alternatives Considered, Trade-offs, Implementation Plan (phases/steps), RDR, Validation, References, Notes. RDRs have a lifecycle (Draft → Accepted → Final → Implemented). They live under `docs/rdrs/` with sequential numbering.

RDRs are currently authored manually by humans. There is no automation around RDR creation — the `lid_planning` goal can *convert* existing RDRs into LID artifacts (RDR-051, capability 4), lid_planning is not feature creation — it only works on existing intent.

### What LID provides (relevant to this RDR)

Per `docs/lid/README.md` and RDR-051, LID (Linked-Intent Development) is the design-before-code method that Paid already supports through detection (`projects.lid_mode`), LID-aware prompt injection (`Lid::InjectIntoPrompt`), the `lid_planning` goal (brownfield analysis + Planning PR), and the intent-confirmation PR review loop.

For this RDR, LID matters because:

- **If the project is LID-enabled**, the RDR's authored intent maps directly onto HLD/LLD/EARS (RDR-051 § Conversion table). The feature-creation flow can chain into `lid_planning` to materialize the RDR into LID artifacts before or alongside issue creation.
- **If the project is not LID-enabled but the user wants LID**, the feature-creation flow should offer to bootstrap LID first (via the existing `lid_planning` adoption path), then proceed.
- **LID replaces CIRs for intent tracking.** Per the user's direction, we do not create Change Intent Records — LID's design tree provides the intent-tracking surface.

### Paid's run model today

- **Agent run goals** (`AgentRun::GOALS`): `create_pr`, `create_issue`, `review`, `enhance_issue`, `analyze_issue`, `lid_planning`. `AgentRun#prompt_for_goal` selects the prompt builder per goal. A new goal is the natural extension point.
- **`create_issue` goal**: takes a `custom_prompt`, runs the agent containerized (no repo clone unless `source_pull_request_number` is present), and creates a GitHub issue from the agent's output. This is the closest existing goal — but it produces a single issue, not an RDR PR + issue tree.
- **`lid_planning` goal**: produces docs-only changes and opens a Planning PR. This is the precedent for docs-only PR output from a run. The `create_feature` goal produces a similar docs-only PR (the RDR) but goes further: it also files implementation issues.
- **Issue enhancement** (`enhance_issue`): the synchronous human-in-the-chat step that asks intent-focused questions and waits (`paid_state: "needs_input"`). The Q&A style and the needs-input/clarifying-questions flow are the reuse targets for feature-creation Q&A when triggered as a run.
- **Chat system** (RDR-051, capability 2): `ChatSession`/`ChatMessage`, 33+ MCP tools, streaming, write-tool confirmation. Chat is the natural home for synchronous feature-creation Q&A. The chat already has tools for `trigger_agent_run`, `get_project`, `create_issue`, `search_code`, etc.
- **Needs-input flow**: an issue in `paid_state: "needs_input"` with a `paid-needs-input` label is surfaced by `Dashboard::NeedsInputQueue`; `ClarifyingQuestions::Load` / `ClarifyingQuestions::SubmitAnswers` / `ClarifyingQuestions::ClearNeedsInput` carry the questions and answers. This is the Q&A channel for async feature-creation when the feature is triggered as a run rather than in chat.

### Technical environment

- **RDR storage**: RDRs live in the project's own repo at `docs/rdrs/`. The RDR is a file like `RDR-0XX-title.md` plus an updated `docs/rdrs/README.md` index.
- **Issue tree**: GitHub issues with dependency relationships expressed via body text references (e.g., "Depends on #N", "Part of RDR-0XX"). Paid's existing cross-repo issue machinery (`AgentRun#cross_repo_issues`) handles issue creation within a run.
- **Prompt building**: `Prompts::BuildForLidPlanning` is the precedent for a goal-specific prompt builder with structured output requirements.
- **Agent image**: already vendors `docs/lid/` and `bin/coherence-check.mjs` (RDR-051 Phase 1). The agent can read and write RDR files.
- **Prompt evolution**: DB-stored prompts with fallback constants (RDR-009). A `create_feature` prompt follows this pattern.

## Research Findings

### Investigation process

1. Read `docs/rdrs/README.md` end-to-end for the RDR format, lifecycle, and section structure.
2. Touch integration points with LID: read `docs/lid/README.md` and RDR-051 for LID's detection, prompt injection, `lid_planning` goal, and conversion of plan docs to LID artifacts.
3. Traced `AgentRun` — `GOALS`, `prompt_for_goal`, goal predicates, `has_prompt_source` validation, `repo_cloned?` behavior — to locate where a `create_feature` goal plugs in.
4. Traced the chat system (RDR-028) and the needs-input / clarifying-questions flow to determine where the Q&A lands in each entry mode.
5. Examined RDR-044 (Configuration Profiles) as a precedent for chat-driven, multi-step, clarify-then-execute flows with structured Q&A.

### Key discoveries

**`create_issue` is close but wrong.** It produces a single issue from a custom prompt. Feature creation produces a docs-only PR (the RDR) *plus* a tree of linked issues. The output shape, prompt, and completion semantics are distinct. A dedicated `create_feature` goal keeps `prompt_for_goal` switching clean and allows the run to open a PR *and* file issues — something `trigger_agent_run` cannot do (it never opens a PR).

**`lid_planning` is the precedent for docs-only PRs.** A `create_feature` run opens a docs-only PR containing the RDR markdown, much like a `lid_planning` run opens a docs-only PR containing LID LLD/EARS artifacts. The `Lid::PlanningContract` server-side output validator (RDR-051) is a model for a `Features::RdrContract` that validates the RDR's required sections.

**Two Q&A channels, same question style.** RDR-051 established that intent-focused questions (problem, desired behavior, constraints, rejected alternatives, scope, done-ness) are universal good practice. The feature-creation flow reuses this question style in two modes:

- **Chat**: the chat agent asks questions inline, iterates until ready, then triggers a `create_feature` run via the existing `trigger_agent_run` MCP tool. No new chat infrastructure needed — just a new system-prompt clause and the ability to pass a rich feature brief as `custom_prompt`.
- **Run (needs-input)**: if triggered directly (UI/API) with insufficient detail, the run posts clarifying questions via the `<!-- paid:enhance-issue -->` comment pattern and moves to `paid_state: "needs_input"`, riding the existing needs-input queue. The UX is similar to issue enhancement; the UI can be reused or lightly adapted.

**RDR numbering must be derived from the repo.** The agent reads existing `docs/rdrs/RDR-*.md` files, finds the highest number, and increments. This is a prompt instruction, not a Paid-side computation — the repo is the source of truth (consistent with RDR-051's "repo stays the source of truth" tenet).

**The Q&A is the differentiator.** Unlike `create_issue` (which takes whatever text it is given), feature creation *requires* detail to produce a good RDR. The run must either arrive with sufficient detail (from chat) or pause for it (needs-input). A run that produces a shallow RDR wastes a PR cycle.

### The tension and its resolution

RDR creation is a design activity that benefits from iteration. A single autonomous run cannot pause mid-execution to ask the user a question. But Paid already has two human-in-the-loop channels that resolve this:

| Entry mode | Q&A surface | Why |
|---|---|---|
| Chat-initiated | **Synchronous chat** | The chat agent asks questions, iterates with the user, and only triggers the `create_feature` run when the feature brief is complete. The run executes against settled intent. |
| Run-initiated (UI/API) | **Needs-input / clarifying-questions** | The run is triggered with whatever detail the user provided. If insufficient, it posts clarifying questions via the `<!-- paid:enhance-issue -->` comment and moves to `paid_state: "needs_input"`. The user answers on the issue; the run resumes. |

This mirrors RDR-051's reconciliation of LID's mandatory stops with Paid's autonomous run model — the stops land in the pre-run Q&A, not mid-run.

## Proposed Solution

### Approach

A new agent run goal `create_feature` with two entry paths and LID-aware chaining. Five components:

1. **Detection** — the run checks `project.lid_mode` and whether the user has requested LID for this feature.
2. **Feature brief** — a structured brief collected via chat or needs-input Q&A that captures the intent-focused answers.
3. **RDR generation** — the agent researches the codebase, writes the RDR markdown, and opens a docs-only PR.
4. **Issue tree decomposition** — the agent decomposes the RDR's Implementation Plan into a tree of linked GitHub issues.
5. **LID chaining** (conditional) — if LID is enabled or requested, chain into `lid_planning` to convert the RDR into LID artifacts.

### Technical design

#### 1. The `create_feature` goal

Add `"create_feature"` to `AgentRun::GOALS`. Add goal predicates, `prompt_for_goal` branch, and the `has_prompt_source` exemption (like `lid_planning`, it derives its prompt from a builder, not from an issue or custom prompt).

```
AgentRun::GOALS = %w[create_pr create_issue create_feature review enhance_issue analyze_issue lid_planning].freeze
```

The `create_feature` goal:

- Always clones the repo (needs to read existing code + RDRs and write RDR files).
- Derives its prompt from `Prompts::BuildForCreateFeature` (new), not from `custom_prompt`. The feature brief is passed via `external_metadata["feature_brief"]`.
- Produces a docs-only PR (`docs/rdrs/`) and files issues.
- Is repo-cloned (`repo_cloned?` returns true unconditionally for this goal).

#### 2. Feature brief format

The feature brief is a structured JSON object stored in `external_metadata["feature_brief"]`:

```json
{
  "title": "Add dark mode",
  "problem": "Users want a dark theme to reduce eye strain at night",
  "desired_behavior": "When the user toggles dark mode, the UI switches to a dark color palette across all pages",
  "constraints": ["Must support system preference detection", "No flash of light theme on load"],
  "rejected_alternatives": ["CSS-only variables — rejected because we need server-side rendering support"],
  "scope": { "in": ["Color palette", "Toggle in settings", "Persistence"], "out": ["Themed syntax highlighting in code blocks"] },
  "done_criteria": "Dark mode is toggleable, persists across sessions, respects system preference, and passes visual regression tests",
  "lid_requested": false,
  "target_rdr_number": null
}
```

#### 3. RDR generation

The `create_feature` run clones the repo, reads `docs/rdrs/README.md` and the existing `docs/rdrs/RDR-*.md` files, and derives the next sequential number by finding the highest existing number and incrementing (a prompt instruction, not a Paid-side computation — consistent with the "repo stays the source of truth" tenet from RDR-051). It then researches the codebase (the same repo-read capability `lid_planning` already has) to ground the RDR's Context and Research Findings sections in real files and symbols, and writes `docs/rdrs/RDR-0XX-<slug>.md` following the section structure in `docs/rdrs/README.md`.

Before the run opens the PR, a server-side validator — `Features::RdrContract`, modeled directly on `Lid::PlanningContract` (`app/services/lid/planning_contract.rb`) — checks that the generated file contains the required sections (Metadata, Problem Statement, Context, Research Findings, Proposed Solution, Alternatives Considered, Trade-offs and Consequences, Implementation Plan, Validation) and that `docs/rdrs/README.md`'s index has been updated with the new row. A missing section fails the contract the same way a missing HLD/LLD section fails `PlanningContract#call` today (`missing` list, `valid?` false) — the run does not open a PR with an incomplete RDR.

The PR is docs-only (`docs/rdrs/` only), opened the same way `lid_planning`'s Planning PR is opened today, and its description links back to the feature brief for reviewer context.

#### 4. Issue tree decomposition

Decomposition happens in the same run, after the RDR passes the contract check, so the issue tree and the RDR it implements are generated from the same grounded understanding of the codebase — not a second pass with stale context.

The agent reads the RDR's own Implementation Plan (§3) and produces one epic issue plus one issue per phase (or per task, for small RDRs where phases are already task-sized). Dependencies between issues are expressed as body text using the existing convention (`Issues::ParseDependencies`, `app/services/issues/parse_dependencies.rb`): `Depends on #N` / `Blocked by #N` inline, or a `## Dependencies` section for multiple links — the same syntax auto-pick already parses, so the filed tree is blocked/unblocked correctly without new dependency infrastructure. Each issue body also references the RDR by number (`Part of RDR-0XX`) so the issue is traceable back to the specification that produced it.

Issue creation reuses the existing cross-repo issue-filing path (`AgentRun#cross_repo_issues`, `app/models/agent_run.rb:1919`) rather than a new mechanism — `create_feature` files issues the same way other goals record filed issues, just filing several instead of one.

Issues are filed only after the RDR PR is opened (not after it merges) — the epic issue's body links to the (open) PR, so a reviewer evaluating the RDR can see the shape of the proposed decomposition alongside it, and can request changes to either before either is accepted. If the RDR PR is closed without merging, the run is responsible for closing the filed issues it created (mirroring how a rejected Planning PR leaves no orphaned LID artifacts).

#### 5. LID chaining (conditional)

If `project.lid_mode` is set, or the feature brief's `lid_requested` is `true`, the run chains into the existing `lid_planning` goal after the RDR PR is opened, passing the new RDR's path so `lid_planning` treats it as the input document (the same role a hand-written RDR plays for `lid_planning` today, per RDR-051's conversion table). This is a second `AgentRun` triggered with `lid_planning` as its goal, not new logic inside `create_feature` — it reuses the goal as-is, keeping the two-execution-model separation RDR-051 established for `lid_planning`'s docs-only-PR output.

If `lid_mode` is not set and `lid_requested` is `false`, `create_feature` completes after filing the issue tree — no LID artifacts are produced, and the filed issues are picked up by the normal (non-LID) `create_pr` flow.

If `lid_mode` is not set but `lid_requested` is `true`, the run's completion message tells the user LID bootstrap is required first and offers to trigger `lid_planning`'s adoption path (RDR-051) before continuing — it does not silently skip LID or silently bootstrap it without confirmation, since adoption changes repo-wide conventions.

### Decision rationale

1. **One new goal, not a new subsystem.** `create_feature` is deliberately shaped like `lid_planning` (docs-only PR from a containerized, codebase-aware run) plus one additional capability (filing an issue tree). Reusing `prompt_for_goal`, container provisioning, and `cross_repo_issues` means the only genuinely new code is the RDR/feature-brief prompt, `Features::RdrContract`, and the decomposition step itself.
2. **Contract-gate the RDR before the PR, not after.** `Lid::PlanningContract` established the pattern of validating structure before opening a PR rather than relying on human review to catch missing sections. `Features::RdrContract` applies the same gate to RDR generation, catching the "generation cut off mid-document" failure mode before it reaches review.
3. **Decompose in the same run as generation.** A second run re-reading the RDR would re-derive context the first run already had, doubling cost for no accuracy gain. Decomposing immediately after the contract check keeps the RDR and its issue tree consistent with each other.
4. **LID chaining is a second run, not inline logic.** Keeping `lid_planning` as a distinct triggered run (rather than folding its logic into `create_feature`) preserves RDR-051 Decision #4 (distinct output shape → distinct goal) and avoids `create_feature` growing a second, conditional output contract.

## Alternatives Considered

### Alternative 1: Skip the pre-run Q&A gate; let `create_feature` pause mid-run instead

**Description**: Trigger `create_feature` immediately with whatever detail is available, and have the run itself post clarifying questions and pause (rather than requiring chat or needs-input to settle the brief *before* the run starts).

**Pros**: One fewer concept for users to learn — always "just trigger the run."

**Cons**: Agent runs cannot pause mid-execution and resume with new input; they are triggered, run, and complete (or fail). Building resumable mid-run pauses would be new orchestration machinery, not a use of existing capability.

**Reason for rejection**: The two existing human-in-the-loop channels (chat, needs-input) already solve this without new orchestration primitives. This is the same reasoning RDR-051 applied to reconcile LID's mandatory stops with Paid's autonomous run model (§ The tension and its resolution).

### Alternative 2: Fold `create_feature` into the `lid_planning` goal

**Description**: Extend `lid_planning` to also accept a feature brief and produce both the RDR and (for LID projects) the LID artifacts in one run, instead of adding a separate goal.

**Pros**: One goal instead of two; no chaining step.

**Cons**: `lid_planning`'s output contract today is LID artifacts from an *existing* RDR or brownfield codebase (RDR-051, capability 4) — it has no issue-tree-filing capability, and folding that in would give it two unrelated jobs (LID conversion vs. RDR+issue-tree authoring) with two different completion criteria. Non-LID projects would also gain no value from a goal named for LID.

**Reason for rejection**: Same conclusion RDR-052 (Alternative 3) reached for a similar merge proposal: distinct output shapes and confirmation surfaces belong in distinct goals. `create_feature` produces an RDR PR + issue tree unconditionally; `lid_planning` conversion is conditional and reused as-is.

### Alternative 3: Generate the issue tree without an RDR (skip the specification document)

**Description**: Decompose the feature brief directly into a linked issue tree, skipping the RDR document — faster time-to-issues, no PR review step.

**Pros**: Fewer artifacts, faster to "issues exist."

**Cons**: Loses the design-review checkpoint an RDR provides (a human can push back on the *approach* before dozens of issues exist), and loses the traceability surface (`Part of RDR-0XX`) that lets someone later understand *why* an issue tree looks the way it does. Directly contradicts the Problem Statement's framing of specification as the highest-leverage, most labor-intensive missing piece.

**Reason for rejection**: Skipping the RDR optimizes for the wrong metric (time-to-issues) at the expense of the actual gap this RDR exists to close (missing specification).

## Trade-offs and Consequences

### Positive consequences

- **Closes the highest-leverage gap.** The user no longer has to bridge "I want to build X" to "here are the issues Paid can pick up" by hand.
- **Reuses proven infrastructure.** Container provisioning, docs-only PR opening, `cross_repo_issues`, and the needs-input/clarifying-questions machinery are all reused as-is; only the goal, prompt builder, and contract are new.
- **Structural quality gate.** `Features::RdrContract` catches incomplete RDRs before they reach a human reviewer, the same way `PlanningContract` does for LID artifacts.
- **LID-day-one option.** Projects that want intent tracking get it from the first PR of a feature, not bolted on after the fact.

### Negative consequences

- **Two-run chain for LID projects.** `create_feature` → `lid_planning` is two container boots and two PR review cycles instead of one, when LID chaining applies.
- **RDR quality depends on brief quality.** A thin feature brief (chat abandoned early, or minimal needs-input answers) produces a thin RDR even though the contract validates *structure*, not *content* depth.
- **Issue-tree decomposition is a judgment call.** Splitting an Implementation Plan into epic/phase/task issues is itself a design decision the agent makes; a poorly decomposed tree (too coarse or too fine) creates rework.

### Risks and mitigations

- **Risk**: Generation is cut off mid-document and produces an incomplete RDR PR.
  **Mitigation**: `Features::RdrContract` blocks the PR from opening until all required sections are present.
- **Risk**: The filed issue tree references an RDR PR that is later rejected or substantially reworked, leaving stale issues.
  **Mitigation**: Issues are filed against the still-open RDR PR (not a merged one); if the PR is closed unmerged, the run closes the issues it filed. See Outstanding Questions for the merge-timing alternative.
- **Risk**: `lid_requested: true` on a non-LID project triggers an unwanted repo-wide LID bootstrap.
  **Mitigation**: The run only *offers* to bootstrap LID and waits for confirmation; it never bootstraps silently.

## Implementation Plan

> Status: Implemented. All five phases shipped.

### Phase 1: `create_feature` goal and feature brief

- Add `"create_feature"` to `AgentRun::GOALS`, goal predicates, `prompt_for_goal` branch, and the `has_prompt_source` exemption.
- Define the feature brief JSON shape (§2) and wire it through `external_metadata["feature_brief"]`.
- Add the chat-side system-prompt clause so the chat agent can gather a brief and trigger the run via `trigger_agent_run`.
- Add the needs-input path so a directly triggered run with an insufficient brief posts clarifying questions and pauses.

### Phase 2: RDR generation and the contract gate

- Build `Prompts::BuildForCreateFeature`, instructing repo research, RDR numbering derivation, and RDR authoring per `docs/rdrs/README.md`'s section structure.
- Build `Features::RdrContract` (modeled on `Lid::PlanningContract`) and wire it into the docs-only PR opening step so an incomplete RDR blocks the PR.

### Phase 3: Issue tree decomposition

- Decompose the RDR's Implementation Plan into an epic + phase/task issues using `Issues::ParseDependencies`-compatible dependency text.
- File issues via the existing `cross_repo_issues` path, each referencing the RDR by number.
- Handle the RDR-PR-closed-unmerged case by closing the issues the run filed.

### Phase 4: LID chaining

- Trigger `lid_planning` as a follow-on run when `lid_mode` is set or `lid_requested` is true, passing the new RDR as input.
- Surface the LID-bootstrap offer (not silent bootstrap) when `lid_requested` is true but `lid_mode` is unset.

### Phase 5: Validation and iteration

- Run the scenarios in Validation below against real feature briefs; measure RDR completeness (contract pass rate on first attempt) and issue-tree quality.

## Dependencies

- Existing container provisioning + docs-only PR opening path (`lid_planning` precedent).
- `Lid::PlanningContract` (`app/services/lid/planning_contract.rb`) as the structural model for `Features::RdrContract`.
- `Issues::ParseDependencies` (`app/services/issues/parse_dependencies.rb`) for the dependency-text convention the filed issue tree must follow.
- `AgentRun#cross_repo_issues` (`app/models/agent_run.rb:1919`) for issue-filing bookkeeping.
- Chat's `trigger_agent_run` MCP tool and the needs-input/clarifying-questions machinery (`ClarifyingQuestions::Load` / `SubmitAnswers` / `ClearNeedsInput`) for the two Q&A entry paths.

## Validation

### Testing approach

1. Unit: `Features::RdrContract` fails validation when a required RDR section is missing, and passes when all are present.
2. Integration: a chat-initiated `create_feature` run (brief already settled) produces a docs-only PR containing a contract-valid RDR and no code changes.
3. Integration: a directly triggered `create_feature` run with an insufficient brief posts clarifying questions and moves to `paid_state: "needs_input"`, matching the existing needs-input flow.
4. Integration: the filed issue tree's dependency text is parseable by `Issues::ParseDependencies` and each issue references the source RDR.
5. Integration: `lid_requested: true` with `project.lid_mode` unset results in an offer to bootstrap LID, not a silent bootstrap or a silent skip.

### Test scenarios

1. **Scenario**: Chat user iterates on a feature brief for "add dark mode" until the brief is complete, then triggers `create_feature`.
   **Expected**: The run opens a single docs-only PR with a contract-valid RDR and files an epic + phase issues linked back to it.
2. **Scenario**: A `create_feature` run is triggered from the UI with only a one-line description.
   **Expected**: The run posts clarifying questions via the needs-input flow instead of generating a thin RDR.
3. **Scenario**: `create_feature` runs on a project with `lid_mode` set.
   **Expected**: After the RDR PR opens, a follow-on `lid_planning` run is triggered against the new RDR.
4. **Scenario**: The RDR generation is interrupted or the agent stops before completing all sections.
   **Expected**: `Features::RdrContract` blocks the PR; no incomplete RDR reaches review.

## Resolved Decisions

- **RDR numbering** — derived by the agent from the repo (highest existing `docs/rdrs/RDR-*.md` number + 1), not computed by Paid. Consistent with RDR-051's "repo stays the source of truth" tenet.
- **LID replaces CIRs** — no separate Change Intent Records; LID's design tree is the intent-tracking surface for `create_feature` output, per the user's direction (§ What LID provides).
- **Decomposition timing** — issue-tree decomposition happens in the same run as RDR generation, not a separate run, so both are grounded in the same codebase research pass.

## Resolved Questions

- **Issues filed at PR-open time** (current design): the implementation files issues when the RDR PR is opened, giving reviewers the full picture sooner. The run closes filed issues if the RDR PR is rejected.
- **No issue-tree cap**: no artificial cap on the number of filed issues. The agent's token budget naturally bounds the decomposition.
- **Related Issues** (Metadata) now reference the implementation chain: #3305 (chat), #3306 (run/needs-input), #3307 (LID), #3308 (closeout + E2E tests).

## 2026-08-11 Closeout

Shipped implementation matches the RDR's five-phase plan:

- **Phase 1 (`create_feature` goal + feature brief)**: `create_feature` added to `AgentRun::GOALS`, goal predicates wired, `prompt_for_create_feature` builds from `external_metadata["feature_brief"]`, chat system-prompt clause included, needs-input path via `ClarifyingQuestions::ClearNeedsInput`.
- **Phase 2 (RDR generation + contract gate)**: `Prompts::BuildForCreateFeature` built, `Features::RdrContract` gates docs-only PRs — incomplete RDRs are caught before review.
- **Phase 3 (issue tree decomposition)**: Cross-repo issue filing via `cross_repo_issues`, each issue references the source RDR (`Part of RDR-053`), dependency text is `Issues::ParseDependencies`-compatible.
- **Phase 4 (LID chaining)**: `ChainLidPlanningActivity` triggers a follow-on `lid_planning` run when `project.lid_mode` is set, reusing the existing `lid_planning` machinery. Skips silently when LID is not enabled.
- **Phase 5 (validation)**: Contract pass rate verified via `Features::RdrContract` specs; E2E integration tests (`spec/integration/create_feature_e2e_spec.rb`) cover chat, run, needs-input, and LID paths.

### Evidence

| Acceptance criterion | Implementation | Tests |
|---|---|---|
| New `create_feature` goal in `GOALS` | `app/models/agent_run.rb:29` (`GOALS = %w[... create_feature]`) | `spec/models/agent_run_spec.rb:3319` |
| Goal predicate `create_feature_goal?` | `app/models/agent_run.rb:1579` | `spec/models/agent_run_spec.rb:622-633` |
| `repo_cloned?` always true for create_feature | `app/models/agent_run.rb:1610-1611` | `spec/models/agent_run_spec.rb:655-659` |
| Prompt builder from feature brief | `app/models/agent_run.rb:2780-2795`, `app/services/prompts/build_for_create_feature.rb` | `spec/models/agent_run_spec.rb:1805-1852` |
| Chat system-prompt clause | `app/services/chat_sessions/build_system_prompt.rb:87` | `spec/services/chat_sessions/build_system_prompt_spec.rb:52` |
| Needs-input pause + resume | `app/temporal/activities/create_agent_run_activity.rb:131-134`, `app/services/clarifying_questions/clear_needs_input.rb:31-38` | `spec/temporal/activities/create_agent_run_activity_spec.rb:1114-1199`, `spec/services/clarifying_questions/clear_needs_input_spec.rb:72-97` |
| RDR contract (section gate) | `app/services/features/rdr_contract.rb` | `spec/services/features/rdr_contract_spec.rb` |
| Docs-only PR allowlist | `app/temporal/activities/create_pull_request_activity.rb:857-884` | `spec/temporal/activities/create_pull_request_activity_spec.rb:825-950` |
| LID chaining | `app/temporal/activities/chain_lid_planning_activity.rb` | `spec/temporal/activities/chain_lid_planning_activity_spec.rb` |
| E2E integration | `spec/integration/create_feature_e2e_spec.rb` | (this closeout) |

### Audit report

See [`audit-report-2026-08-11-rdr-053.md`](audit-report-2026-08-11-rdr-053.md).

### Status: Implemented

All five phases shipped with test coverage. No remaining gaps.
