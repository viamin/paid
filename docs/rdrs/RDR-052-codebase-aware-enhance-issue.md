# RDR-052: Codebase-Aware Issue Enhancement

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-05
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related RDRs**: RDR-051 (LID-aware agent runs — revises its Decision #6 stance on `enhance_issue`), RDR-027 (Auto-enhance and knowledge-base evolution), RDR-004 (Container isolation), RDR-007 (agent-harness), RDR-021 (Knowledge base)
- **Input**: `docs/brainstorms/codebase-aware-enhance-issue-requirements.md`
- **Related Issues**: #3254 (Phase 1 — containerized read-only execution), #3255 (Phase 2 — codebase-grounded question generation + re-evaluation), #3256 (closeout audit — blocked on #3254/#3255)

## Problem Statement

`enhance_issue` is the step that decides whether an issue is ready for an implementation run, and — when it isn't — asks the human the questions that would get it there. It also owns the re-evaluation loop: after the human answers, `enhance_issue` runs again to judge whether the answers made the issue actionable. Both jobs, *asking* and *judging sufficiency*, are codebase questions at their core.

Today it performs both from a direct `AgentHarness.send_message` call inside the Temporal worker process, with `tools: :none` and no repository access. Its only view of the codebase is retrieved knowledge-base fragments (`Knowledge::Search` + `Knowledge::ContextBundle::Build`). Two failures follow:

1. **It asks humans questions the code could answer.** Observed on a real issue: it asked "are there existing shape models in `Models.swift`?" and "is this for macOS or iOS?" — both directly readable from the repo. The readiness gatekeeper routes to humans the very context it could retrieve itself.
2. **It judges readiness against a snapshot.** Sufficiency is assessed against knowledge-base fragments that may be stale or incomplete, so the verdict that authorizes a `create_pr` run is less informed than the run it gates.

A structural symptom made this observable: the direct call reads its API key from `ANTHROPIC_API_KEY` in the environment, while containerized runs (`create_pr`, `lid_planning`) source credentials from the DB-stored runner credential. When the environment lacked the ENV var, `enhance_issue` failed while containerized runs succeeded — exposing both the credential bifurcation and the fact that this step runs outside the container model the rest of the agent system uses.

RDR-051 Decision #6 deliberately kept `enhance_issue` as the lightweight, prompt-only elicitation step. This RDR revises that stance for the *execution model* (it should be codebase-aware) while preserving its *role* (elicitation and readiness gating, not artifact production).

## Context

### The enhancement pipeline today

On projects with `auto_enhance_enabled`, the flow is already two-tiered (`agent_execution_workflow.rb:175`):

```ruby
followup_goal = result[:sufficient_context] ? "create_pr" : "enhance_issue"
```

1. A new issue is auto-picked and `analyze_issue` runs first — a lightweight direct-LLM readiness gate that returns a JSON verdict (`sufficient_context` + `missing_context_areas`) and routes, posting nothing.
2. `sufficient` → `create_pr`. `insufficient` → `enhance_issue`.
3. `enhance_issue` posts either implementation context or clarifying questions via the `<!-- paid:enhance-issue -->` marker and moves the issue to `paid_state: "needs_input"`.
4. When the user answers and the `paid-needs-input` label clears, `detect_enhance_issue_rechecks` (`fetch_issues_activity.rb`) queues an `enhance_issue` re-evaluation run (up to `max_enhance_issue_reevaluation_rounds`, default 3).

So the two-tier gate the project needs **already exists**: `analyze_issue` is the lightweight gate; `enhance_issue` is the enhancement step. Both are direct-LLM today. This RDR changes only `enhance_issue`'s execution model; the gate and routing are unchanged.

### What `enhance_issue` owns (and must keep)

- The `<!-- paid:enhance-issue -->` comment marker and the needs-input / clarifying-questions flow (`ClarifyingQuestions::Load` / `SubmitAnswers` / `ClearNeedsInput`), including the dashboard queue and answer form.
- The re-evaluation loop and `enhance_issue_round` accounting.
- The output contract: either clarifying questions or implementation context, plus label state.

### Existing capability to reuse

`create_pr`, `review`, and `lid_planning` already run as containerized agents with repo access and credentials injected from the DB-stored runner credential. `lid_planning` (RDR-051) is the closest analog: a containerized, codebase-aware goal — but pointed at LID artifact *production*, not readiness *assessment*. The capability `enhance_issue` needs already exists in the system; it lives on the other goal.

### Prior fix that composes

PR #3235 fixed comment admission so the bot's prior clarifying Q&A reaches the `enhance_issue` LLM (previously dropped by the human-only trust filter). That fix is what makes prior answers visible to a containerized re-evaluation run; this RDR builds on it.

## Research Findings

### Investigation process

1. Traced the enhancement pipeline end to end: `analyze_issue` (gate) → routing → `enhance_issue` (questions/context) → needs-input flow → `detect_enhance_issue_rechecks` (re-evaluation).
2. Confirmed both `analyze_issue` and `enhance_issue` are direct-LLM calls (`tools: :none`, no container) and share the same `trusted_comments` bot-excluding filter.
3. Confirmed the credential bifurcation: container runs inject from `runner_credentials` (DB → `pi_auth.json`, `config/initializers/agent_harness.rb`); direct `send_message` calls read `ANTHROPIC_API_KEY` from ENV.
4. Confirmed `lid_planning` already provides the containerized, codebase-aware pattern this needs.
5. Reviewed RDR-051 Decision #6 (the stance this revises) and RDR-027 (auto-enhance).

### Key discoveries

**The two-tier gate already exists.** The brainstorm initially explored building a lightweight "is this issue too thin?" gate. Investigation showed `analyze_issue` already is that gate and already routes correctly (`sufficient` → `create_pr`, `insufficient` → `enhance_issue`). The project is therefore *not* "build a two-tier model"; it is "make the enhancement tier codebase-aware." `analyze_issue` needs no structural change.

**Both of `enhance_issue`'s jobs benefit from the same change.** Question-generation ("what's missing?") and answer-sufficiency judgment ("are the answers enough?") are both codebase questions. A single execution-model change improves both, which is the unifying argument for the work.

**The readiness gatekeeper is currently less informed than the run it authorizes.** `create_pr` runs containerized with full repo access; `enhance_issue` authorizes it from a KB snapshot. That is an inverted capability gradient.

**`analyze_issue` shares the same `trusted_comments` bug and KB-blindness**, but the impact is lower because it only routes (it does not generate questions). Its fix is a separate follow-up, explicitly out of scope here.

## Proposed Solution

### Approach

Change `enhance_issue`'s execution model from a direct LLM call to a **read-only containerized agent with repository access**, reusing the existing container provisioning and runner-credential path. Preserve its role, output contract, and ownership of the needs-input / re-evaluation machinery. Leave `analyze_issue` and the next-stage routing unchanged.

### Technical design

**1. Containerized, read-only execution.** `enhance_issue` runs through the same container provisioning steps as `create_pr` / `lid_planning` (currently the workflow short-circuits `enhance_issue` straight to the activity at `agent_execution_workflow.rb:151`, skipping provisioning). The run is **read-only**: the agent explores the repository to ground its questions and assessment but cannot modify files, commit, or push. Its only outputs remain the posted comment and label state.

Read-only is enforced as **structural + behavioral**:

- *Structural* — the workspace bind mount uses `:ro` instead of the default `:rw` (container workspaces are bind-mounted today via `Binds` at `app/services/containers/provision_for_chat.rb:203`). State/scratch volumes (the existing `STATE_VOLUME_DIRS` pattern) remain writable so runner tooling that needs scratch space still functions; only the repo mount is read-only.
- *Behavioral* — the prompt states the workspace is read-only so the agent doesn't waste effort attempting writes that would fail.

**Shallow clone.** The enhancement run uses the existing shallow clone (`--depth 1`, already the default at `app/services/containers/git_operations.rb:877` and in chat provisioning at `provision_for_chat.rb:295`). Enhancement assesses current state, not history, so it takes the default and skips the `unshallow` step that only history-dependent operations (rebase) require.

**2. Grounded question generation.** The agent reads the repo alongside the issue, conversation, and KB context. It self-answers what the code determines (existing models, platform targets, persistence format, current patterns) and asks the human only about genuine product, scope, or intent ambiguities.

**3. Grounded sufficiency judgment.** On re-evaluation, the agent reads the codebase *and* the prior Q&A (visible via comment admission, PR #3235) and judges whether the answers plus the actual code yield enough context to proceed — not the KB snapshot alone.

**4. Preserved contract.** The `<!-- paid:enhance-issue -->` marker, the needs-input / clarifying-questions flow, the re-evaluation loop, and `enhance_issue_round` accounting are unchanged. No new UI surfaces or issue states. Next-stage routing after "sufficient" is unchanged.

**5. Credential unification.** The run authenticates via the injected runner credential (DB-stored), removing this step's dependency on `ANTHROPIC_API_KEY` in the environment.

### Decision rationale

1. **Preserve the role, change the engine.** Moving the needs-input machinery to a new goal would disrupt the integrated UI path and gains nothing. `enhance_issue` keeps its output shape (RDR-051 Decision #4 — distinct output shape → distinct goal) and simply gains a better engine. This is the smallest change that delivers the value.
2. **Read-only, not read-write.** `enhance_issue` assesses and elicits; it does not implement. Read-only keeps it cleanly distinct from `create_pr` and prevents drift into making changes.
3. **Leave `analyze_issue` as-is.** It already gates and routes correctly. Widening this RDR to cover it would conflate the "ask/judge" change with a "gate" change. Its parallel `trusted_comments` bug and KB-blindness are a separate follow-up.
4. **Revise RDR-051 Decision #6 deliberately, narrowly.** RDR-051 kept `enhance_issue` lightweight because it runs on every enhanced issue and "must stay fast/cheap." This RDR accepts a cost increase on the enhancement tier in exchange for materially better questions and verdicts — and notes that the gate (`analyze_issue`) still provides the cheap first pass, so the container cost lands only on issues the gate already flagged as insufficient (and on re-evaluation rounds).

### Implementation example

```text
# analyze_issue returns sufficient_context: false for an under-specified issue.
# The workflow routes to enhance_issue, now containerized:

#   The enhance_issue agent, in a read-only container:
#     - reads the issue + trusted conversation + KB context (as today)
#     - ALSO reads the repo: existing models, platform targets, persistence layer
#     - self-answers "are there shape models?" / "macOS or iOS?" from the code
#     - posts ONLY genuine gaps via the <!-- paid:enhance-issue --> marker:
#         ## Clarifying questions
#         1. Should drawn shapes overlay an imported image, or replace it?
#     - moves the issue to needs_input

# User answers. needs-input clears. Re-evaluation runs (containerized):
#     - reads the answers AND the codebase
#     - judges the answers + code = sufficient
#     - posts implementation context (now grounded in real files/symbols)
#     - issue re-enters the queue → create_pr
```

## Alternatives Considered

### Alternative 1: Lightweight read-only codebase access without a container

**Description**: Give the direct `send_message` call structured codebase access (codegraph / repo-read / search) without spinning up a runner.

**Pros**: Cheapest; preserves the fast path; no container boot per run.

**Cons**: No agentic exploration — a single enriched pass cannot follow a thread through the code the way a tool-using agent can. The "self-answer codebase questions" value depends on multi-step exploration (read this file → check that type → confirm the pattern), which a single retrieval pass does not provide.

**Reason for rejection**: The value being pursued (grounded questions and sufficiency judgment) requires exploration, not just richer retrieval. Single-pass enrichment would close part of the gap but not the core "the agent could answer this itself" failure.

### Alternative 2: Tier internally within one `enhance_issue` goal

**Description**: The run does the cheap direct-LLM call first; if uncertain, escalates to a containerized exploration within the same goal.

**Pros**: One mental model; preserves a cheap path.

**Cons**: Conflates two execution models (direct-LLM + container) in one goal, fighting RDR-051 Decision #4 and muddying `prompt_for_goal` routing. Also redundant with `analyze_issue`, which is *already* the cheap first pass that routes.

**Reason for rejection**: The cheap-first-pass tier already exists as `analyze_issue`. Adding internal tiering to `enhance_issue` duplicates the gate and conflates execution models.

### Alternative 3: Merge `enhance_issue` into `lid_planning`

**Description**: Fold readiness assessment into the existing containerized, codebase-aware `lid_planning` goal — one codebase-aware goal produces both the assessment and (for LID projects) the artifacts.

**Pros**: Single codebase-aware goal; maximum reuse.

**Cons**: `lid_planning`'s output shape is docs-only LID artifacts in a Planning PR; `enhance_issue`'s is a comment + needs-input label state. Merging conflates two distinct output shapes and two distinct human-in-the-loop surfaces (Planning-PR review vs. issue Q&A), violating the separation RDR-051 Decision #4 established.

**Reason for rejection**: The two goals have distinct output contracts and confirmation surfaces. Borrow the *capability* (containerized codebase access), not the *goal*.

## Trade-offs and Consequences

### Positive consequences

- **Fewer, higher-value questions.** Humans stop answering things the code already says; rounds-to-resolution should drop.
- **Better readiness verdicts.** `create_pr` runs launch against codebase-grounded "sufficient" judgments, reducing failures on underspecified issues.
- **Better implementation context.** When `enhance_issue` posts implementation context, it cites real files/symbols it read, not snapshot inferences.
- **Credential unification.** The enhancement step moves to the runner-credential path, closing the `ANTHROPIC_API_KEY`-from-ENV gap that triggered this work.
- **Composes with PR #3235.** Answers stay visible to the containerized re-evaluation run.

### Negative consequences

- **Higher cost/latency per enhancement run.** A container clone + agent boot replaces a single Haiku-class call. This lands on every issue the gate flags insufficient *and* on each re-evaluation round (up to the cap).
- **Read-only enforcement is a new constraint.** The existing container path is read-write; enforcing read-only for this goal is a structural addition (planning question).
- **Re-evaluation rounds multiply the cost.** The back-and-forth path (up to `max_enhance_issue_reevaluation_rounds`) now spins a container per round — the cost multiplier hits the loop hardest.

### Risks and mitigations

- **Risk**: Per-run container cost makes enhancement prohibitively expensive at scale.
  **Mitigation**: The gate (`analyze_issue`) already filters, so only insufficient issues reach the container. Per-round re-evaluation cost is accepted in v1 (grounding value justifies it); revisit if measurement shows it's material.
- **Risk**: A CLI runner expects to write scratch/todo state to the workspace and hard-fails under a read-only repo mount.
  **Mitigation**: Structural enforcement is settled (`:ro` repo bind, state/scratch volumes remain writable), but the chosen runner must be validated to function read-only before locking — route any required scratch to the writable state volumes rather than the repo mount. Validate in Phase 1.
- **Risk**: The agent over-explores, inflating latency without better questions.
  **Mitigation**: Scope the exploration via the prompt (read the files relevant to the issue area); measure exploration depth vs. question quality during validation.

## Implementation Plan

> Status: Draft. Phases are indicative; the deferred questions below must be resolved during planning before locking.

### Phase 1: Wire `enhance_issue` into container provisioning (read-only)

**Prerequisites:** Confirm the chosen runner functions in a read-only workspace (see Risk below).

- Route `enhance_issue` through the container-provisioning steps instead of short-circuiting to the activity.
- Mount the workspace bind `:ro` (repo read-only); leave state/scratch volumes writable. State the read-only constraint in the prompt.
- Use the default shallow clone (`--depth 1`); skip `unshallow`.
- Authenticate via the runner-credential injection path.

### Phase 2: Codebase-grounded question generation

- Replace the direct-LLM `prompt_for` with an agent prompt that instructs repo exploration to self-answer codebase-determinable questions before asking the human.
- Preserve the `<!-- paid:enhance-issue -->` marker, needs-input flow, and output contract.

### Phase 3: Codebase-grounded re-evaluation

- The re-evaluation run (recheck loop) uses the same containerized, codebase-aware path, reading prior Q&A (via comment admission) + the codebase to judge sufficiency.
- Per-round container cost is **accepted** — the grounding value on the back-and-forth path justifies it. (If later measurement shows it's material, re-evaluation could be lightened, but that is not the v1 design.)

### Phase 4: Validation and cost measurement

- Measure question quality (do agents stop asking codebase-answerable questions?), rounds-to-resolution, and per-run cost/latency against the pre-change baseline.

## Dependencies

- Existing container provisioning + runner-credential injection path (used by `create_pr` / `lid_planning`).
- PR #3235 (comment admission, merged) — makes prior answers visible to the re-evaluation run.
- RDR-004 (container isolation) — for read-only enforcement options.

## Validation

### Testing approach

1. Unit/integration: a containerized `enhance_issue` run produces no file changes/commits (read-only) — AE3.
2. Integration: given an issue whose answers are readable from the repo, `enhance_issue` does not ask them (self-answers from code) — AE1.
3. Integration: re-evaluation reads the codebase alongside prior answers and judges sufficiency against the actual code — AE2.
4. Integration: the run succeeds with `ANTHROPIC_API_KEY` unset, authenticating via the runner credential — AE4.
5. Regression: the needs-input / clarifying-questions / dashboard-queue flow is unchanged end to end.

### Test scenarios

1. **Scenario**: Issue asking to add a feature whose prerequisites already exist in the repo.
   **Expected**: `enhance_issue` self-answers the prerequisite questions from the code and asks only genuine product/scope gaps.
2. **Scenario**: Re-evaluation after the user answers.
   **Expected**: The run reads the codebase + answers and issues a sufficiency verdict grounded in the actual code.
3. **Scenario**: `ANTHROPIC_API_KEY` unset, runner credential configured.
   **Expected**: The containerized run authenticates via the injected credential and succeeds.

## Resolved Decisions

- **Read-only enforcement** — structural + behavioral: workspace bind mounted `:ro` (state/scratch volumes stay writable), plus a prompt statement so the agent doesn't attempt writes. Evidence: container workspaces are bind-mounted today (`app/services/containers/provision_for_chat.rb:203`); `:ro` is a one-option change.
- **Clone depth** — shallow (`--depth 1`), the existing default (`app/services/containers/git_operations.rb:877`). Enhancement needs no history; skip `unshallow`.
- **Per-round re-evaluation cost** — accepted in v1. The grounding value on the back-and-forth path justifies it; revisit only if measurement shows it's material.

## Outstanding Questions (to resolve in planning)

- The `enhance_issue` workflow path (`agent_execution_workflow.rb:151`) currently skips provisioning and short-circuits to the activity — confirm the exact insertion point for the container-provisioning steps. (The chat provisioning path, `app/services/containers/provision_for_chat.rb`, is the closest analog to follow.)
- Which runner is used for the enhancement run, and does it function correctly under a read-only repo mount? Validate before locking Phase 1.

## 2026-08-06 Closeout Attempt — Blocked (Status Remains Draft)

> Follows the [RDR Closeout Checklist](closeout-checklist.md). Full evidence in
> [`audit-report-2026-08-06-rdr-052.md`](audit-report-2026-08-06-rdr-052.md).

A closeout audit was performed against this RDR's plan and acceptance criteria
(R1–R8, AE1–AE4). The audit found that **the implementation has not shipped**.
The dependency chain it requires — Phase 1 (#3254, containerized read-only
execution) and Phase 2 (#3255, codebase-grounded question generation and
re-evaluation) — is absent from the codebase. The shipped `enhance_issue` is
still the pre-RDR direct-LLM call:

- A non-container goal (`app/temporal/activities/create_agent_run_activity.rb:7`
  and `app/services/orchestration_strategies/defaults.rb:220` both list
  `enhance_issue` under `non_container_goals`).
- Short-circuited to its activity before provisioning
  (`app/temporal/workflows/agent_execution_workflow.rb:151-159`, ahead of
  `ProvisionContainerActivity` at `:226`).
- A direct `AgentHarness.send_message(..., tools: :none)` call
  (`app/temporal/activities/enhance_issue_activity.rb:186`, `:213-223`) reading
  its key from ENV — the `ANTHROPIC_API_KEY` gap R2/R7/AE4 target.

Consequently none of R1, R2, R3, R4, R7, AE1, AE2, AE3, or AE4 have shipped code
or test evidence. R5 and R6 ("preserved output contract", "unchanged routing")
hold only vacuously — nothing changed. R8's prerequisite (PR #3235 comment
admission, `enhance_issue_activity.rb:318-326`) is present but composes with the
direct-LLM run rather than a containerized one. Both open planning questions
(workflow insertion point; runner under a read-only mount) remain unresolved
because the work that would resolve them never landed.

Per the closeout checklist, **status is left unchanged at Draft** — not
"Implemented" (no acceptance criterion has code evidence) and not "Partially
Implemented" (no core scope shipped). The LID `issue-enhancement` segment is
coherent for the shipped clarifying-question / comment-admission work and
correctly carries no EARS claims for the codebase-aware execution model until
that model exists; `bin/coherence-check.mjs` is clean.

The closeout will be re-opened when #3254 and #3255 merge: re-verify each
requirement above, add the new execution model's EARS claims to
`docs/intent/issue-enhancement/` alongside the code, confirm the coherence
check is clean, and only then flip the RDR and README index to **Implemented**.
No RDR status change is made in this audit.
