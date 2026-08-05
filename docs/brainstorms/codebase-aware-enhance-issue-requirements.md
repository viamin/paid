---
date: 2026-08-05
topic: codebase-aware-enhance-issue
---

# Codebase-aware issue enhancement

## Summary

Move `enhance_issue`'s question-generation and answer-sufficiency judgment out of a direct LLM call into a read-only containerized agent with repo access, so the clarifying questions it asks and the readiness verdicts it issues are grounded in the actual codebase rather than knowledge-base snapshots. The lightweight gate (`analyze_issue`) and the next-stage routing are unchanged.

---

## Problem Frame

`enhance_issue` is the step that decides whether an issue is ready for an implementation run — and, when it isn't, asks the human the questions that would get it there. It also owns the re-evaluation loop: after the human answers, `enhance_issue` runs again to judge whether the answers made the issue actionable. Both jobs — *asking* and *judging sufficiency* — are codebase questions at their core.

Today it does both from a direct LLM call with no codebase access. Its only view of the repo is retrieved knowledge-base fragments (`Knowledge::Search` + `ContextBundle`). The result is predictable: it asks humans questions the code could answer ("are there existing shape models in `Models.swift`?", "is this macOS or iOS?"), and it judges readiness against a snapshot that may be stale or incomplete. The gatekeeper is blinder than the implementation run it authorizes.

This surfaced concretely: a re-evaluation round re-asked questions a user had already answered (a separate comment-admission bug, fixed in PR #3235), and the harder residual problem — asking things the code already says — remains. A second symptom is structural rather than behavioral: `enhance_issue` runs as a direct `AgentHarness.send_message` call in the worker process, reading its API key from `ANTHROPIC_API_KEY` in the environment, while containerized runs (`create_pr`, `lid_planning`) source credentials from the DB-stored runner credential. That credential bifurcation is what made the failure observable.

RDR-051 already established the architectural seam this sits on: `enhance_issue` is deliberately the lightweight synchronous human-in-the-loop step, while `lid_planning` is the containerized, codebase-aware goal — but pointed at artifact *production*, not readiness *assessment*. The capability `enhance_issue` needs already exists in the system; it just lives on the other goal.

---

## Actors

- A1. **`analyze_issue`** — the lightweight direct-LLM readiness gate. Assesses an issue and routes: `sufficient` → `create_pr`, `insufficient` → `enhance_issue`. Unchanged by this work.
- A2. **`enhance_issue`** — the enhancement step. Generates clarifying questions or implementation context, owns the needs-input / clarifying-questions flow, and re-evaluates answer sufficiency. This is the actor being changed.
- A3. **Project owner / issue author** — the human who answers clarifying questions and whose issue is being gated.
- A4. **`create_pr` / LID-aware implementation run** — the downstream consumer that runs once `enhance_issue` (or `analyze_issue`) declares the issue sufficient.
- A5. **`lid_planning`** — the existing containerized, codebase-aware goal (artifact production). Referenced for context and pattern reuse; not changed.

---

## Key Flows

- F1. **Initial enhancement (codebase-grounded questions)**
  - **Trigger:** `analyze_issue` returns `sufficient_context: false` for a new issue.
  - **Actors:** A1, A2, A3
  - **Steps:** `analyze_issue` routes to `enhance_issue` → `enhance_issue` runs in a read-only container, explores the repo alongside the issue + KB context → it self-answers what the code determines and posts only genuine product/scope questions via the existing marker → issue moves to `needs_input`.
  - **Outcome:** The human receives questions the code could not answer.
  - **Covered by:** R1, R2, R3, R5

- F2. **Answer-sufficiency re-evaluation**
  - **Trigger:** The human answers; the needs-input label clears; the recheck loop queues an `enhance_issue` run.
  - **Actors:** A2, A3, A4
  - **Steps:** `enhance_issue` re-runs in a read-only container, reading the codebase *and* the prior Q&A (visible via comment admission) → it judges whether the answers plus the actual code yield enough context to proceed → `sufficient` re-enters the queue for the next stage; `insufficient` posts further questions (up to the round cap).
  - **Outcome:** The sufficiency verdict is grounded in the real codebase, not a snapshot.
  - **Covered by:** R1, R4, R5, R8

---

## Requirements

**Execution model**

- R1. `enhance_issue` runs as a containerized agent with repo access (the same provisioning path `create_pr`/`lid_planning` use), replacing the in-process direct LLM call.
- R2. The run is **read-only**: the agent may explore the repository to ground its questions and assessment, but cannot modify files, commit, or push. Its only outputs are the posted comment and label state.

**Quality of questions and sufficiency judgment**

- R3. `enhance_issue` must not ask the human clarifying questions whose answers are directly readable from the repository. It self-answers those from the code and asks only about genuine product, scope, or intent ambiguities.
- R4. The answer-sufficiency re-evaluation must judge whether the user's answers *plus the actual codebase* yield enough context to proceed — grounded in code the agent read, not knowledge-base snapshots alone.

**Preserved contract**

- R5. `enhance_issue`'s output contract is unchanged: it posts either clarifying questions or implementation context through the existing `<!-- paid:enhance-issue -->` marker, and continues to own the needs-input / clarifying-questions / re-evaluation loop without new UI surfaces or issue states.
- R6. The next-stage routing after `enhance_issue` declares "sufficient" is unchanged (the issue re-enters the queue for `create_pr` / the LID-aware path).

**Credentials**

- R7. The containerized `enhance_issue` run uses the same runner-credential path as `create_pr` (DB-stored credential, injected into the container), removing this step's dependency on a separate `ANTHROPIC_API_KEY` environment variable.

**Composes with prior work**

- R8. The comment-admission behavior shipped in PR #3235 (the bot's prior clarifying Q&A reaches the LLM) continues to hold for the containerized re-evaluation run.

---

## Acceptance Examples

- AE1. **Covers R3.** Given an issue asking to "add drawing tools" in a repo where `Models.swift` already defines shape types and the project targets are visible, when `enhance_issue` runs, it does *not* ask the human "are there existing shape models?" or "is this macOS or iOS?" — it reads those from the code and asks only about genuine scope/intent gaps.
- AE2. **Covers R4.** Given an issue whose author has answered the initial clarifying questions, when the needs-input label clears and the re-evaluation runs, `enhance_issue` reads the codebase alongside the answers and judges sufficiency against the actual code — not the knowledge-base snapshot alone.
- AE3. **Covers R2.** Given a containerized `enhance_issue` run, the agent explores the repo but produces no file changes, commits, or branch pushes; its only side effects are the comment post and label transition.
- AE4. **Covers R7.** Given an environment where `ANTHROPIC_API_KEY` is unset but runner credentials are configured, a containerized `enhance_issue` run succeeds, authenticating via the injected runner credential rather than the environment variable.

---

## Success Criteria

- Project owners receive fewer, higher-value clarifying questions — none whose answers are readable from the repo — and fewer back-and-forth rounds before an issue is actionable.
- `create_pr` runs launched after an `enhance_issue` "sufficient" verdict fail less often due to underspecification, because the gate that authorized them was codebase-grounded.
- A downstream implementer can tell the handoff is clean: the "sufficient" verdict and any posted implementation context cite real code, not inferred-from-snapshot guesses.

---

## Scope Boundaries

- `analyze_issue` stays a direct-LLM gate. Its parallel `trusted_comments` bug (same bot-excluding filter, unfixed) and its own KB-blindness are a **separate follow-up**, not this work — it only routes, so the impact is lower.
- `lid_planning` is unaffected; it remains the distinct containerized codebase-aware goal for artifact production.
- The lightweight gate does not itself become codebase-aware in this work.
- Next-stage routing (`enhance` → `create_pr` / LID-aware path) is unchanged.
- No new human-facing UI surfaces or issue states.

---

## Key Decisions

- **Keep `enhance_issue`'s role and machinery; only the generation moves into the container.** Moving the needs-input / clarifying-questions flow to a new goal would disrupt the integrated UI path. This follows RDR-051 Decision #4 (distinct output shape → distinct goal) — `enhance_issue` keeps its output shape, it just gains a better engine.
- **Read-only, not read-write.** `enhance_issue` assesses and elicits; it does not implement. Read-only keeps it cleanly distinct from `create_pr` and avoids the agent drifting into making changes.
- **Leave `analyze_issue` as-is.** It already does the gate job and already routes correctly. Widening this work to cover it would conflate the "ask/judge" change with a "gate" change and balloon the scope.

---

## Dependencies / Assumptions

- Depends on the existing container provisioning + runner-credential injection path used by `create_pr` / `lid_planning`.
- Assumes a read-only container mode is enforceable. The existing container path is read-write (it commits); whether read-only can be enforced structurally (vs. relied on via prompt) is a planning question.
- Composes with PR #3235 (comment-admission fix, merged) — that fix is what makes prior answers visible to the containerized re-evaluation run.
- The `enhance_issue` re-evaluation loop (up to `max_enhance_issue_reevaluation_rounds`, default 3) now spins a container per round — the cost multiplier lands hardest on the back-and-forth path, not the first pass.

---

## Outstanding Questions

### Resolve Before Planning

- *None blocking.* Scope, actors, and the preserved contract are settled.

### Deferred to Planning

- **Affects R2.** (Technical) How is read-only enforced in the container? Is there an existing read-only provisioning mode, or must one be added? (`create_pr`'s container is read-write.)
- **Affects R1.** (Technical) Does the containerized `enhance_issue` clone the full repo (like `create_pr`) or use a lighter check-out? Latency/cost tradeoff per run, amplified on the re-evaluation path.
- **Affects R4.** (Needs research) Is the per-round container cost on the re-evaluation loop acceptable, or should re-evaluation stay lighter than the initial question-generation pass? Needs measurement during planning.
- **Affects R5.** (Technical) The `enhance_issue` workflow path (`agent_execution_workflow.rb:151`) currently does no container provisioning — it short-circuits straight to the activity. Wiring it into the container-provisioning steps (currently gated to `create_pr`/`review`/`lid_planning`) is the main structural change; confirm where the read-only constraint plugs in.

> Resolved in RDR-052 (`docs/rdrs/RDR-052-codebase-aware-enhance-issue.md`): read-only = `:ro` repo bind + prompt statement (state volumes stay writable); clone = shallow `--depth 1` (existing default); per-round re-evaluation cost = accepted in v1. The workflow insertion point and runner-read-only validation remain open for planning.
