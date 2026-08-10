# RDR-053: New Feature Creation — RDR-Driven Issue Trees with LID Support

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-09
- **Status**: Draft
- **Type**: Architecture + Process
- **Priority**: P1
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md) (Interactive Chat), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-031](RDR-031-focused-agent-runs.md) (Focused Agent Runs), [RDR-009](RDR-009-prompt-evolution.md) (Feature Creation vs Existing Goals), [RDR-044](RDR-044-configuration-profiles-chat.md) (Chat-Driven Configuration Profiles)
- **Related Issues**: TBD

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

- **Agent run goals** (`AgentRun::GOALS`): `create_pr`, `create_issue`, `create_feature`, `review`, `enhance_issue`, `analyze_issue`, `lid_planning`. `AgentRun#prompt_for_goal` selects the prompt builder per goal. A new goal is the natural extension point.
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
  "lid_requested": false
  "target_rdr_number": null
}
```
