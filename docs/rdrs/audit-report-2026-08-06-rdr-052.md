# RDR-052 Audit Report — 2026-08-06

## Summary

RDR-052 (Codebase-Aware Issue Enhancement) is **not implemented**. The closeout
audit found that the implementation chain it depends on — Phase 1
([#3254](https://github.com/viamin/paid/issues/3254), containerized read-only
execution) and Phase 2 ([#3255](https://github.com/viamin/paid/issues/3255),
codebase-grounded question generation and re-evaluation) — has **not shipped**
into the codebase. `enhance_issue` is still the pre-RDR direct-LLM call: a
non-container goal that short-circuits straight to its activity, with no
repository access and no runner-credential auth.

Per the [RDR Closeout Checklist](closeout-checklist.md) step 1, a criterion is
satisfied only by merged code and tests — never by "the issue is closed." No
acceptance requirement (R1–R8) or acceptance example (AE1–AE4) that depends on
the implementation has shipped code evidence. The RDR therefore **cannot be
finalized to Implemented**. Per lifecycle step 5, its status is left unchanged
at **Draft** (not "Partially Implemented", because none of the core scope
shipped).

This audit was tracked in closeout issue
[#3256](https://github.com/viamin/paid/issues/3256).

## GitHub State

- Closeout issue [#3256](https://github.com/viamin/paid/issues/3256) — this
  audit. Filed with `Depends on #3254` / `Depends on #3255`.
- Implementation dependencies
  [#3254](https://github.com/viamin/paid/issues/3254) (Phase 1) and
  [#3255](https://github.com/viamin/paid/issues/3255) (Phase 2): not present in
  the audited codebase. Their changes are absent from `app/`, `spec/`, and the
  migration history.

## Verified Against The RDR

The audit walked every requirement the RDR-052 plan names (R1–R8) and every
Acceptance Example (AE1–AE4). Findings below cite current code.

### R1 — containerized, read-only execution (Phase 1) — NOT MET

`enhance_issue` is explicitly a **non-container goal**:

- `app/temporal/activities/create_agent_run_activity.rb:7` —
  `NON_CONTAINER_GOALS = %w[enhance_issue analyze_issue].freeze`
- `app/services/orchestration_strategies/defaults.rb:220` —
  `"non_container_goals" => %w[enhance_issue analyze_issue]`

The workflow short-circuits `enhance_issue` straight to its activity **before**
container provisioning, exactly as the RDR's "Outstanding Questions" describe
the to-be-changed state:

- `app/temporal/workflows/agent_execution_workflow.rb:151-159` — the
  `if goal == "enhance_issue"` branch runs `EnhanceIssueActivity` and returns,
  before `ProvisionContainerActivity` (`:226`), `ProvisionServicesActivity`
  (`:188`), `ProvisionMcpServersActivity` (`:195`), and `CloneRepoActivity`
  (`:244`). No container is provisioned for this goal.

No read-only repo/workspace mount exists. The only `:ro` binds in provisioning
are credential-config staging mounts
(`app/services/containers/provision.rb:2411`, `:2419`, `:2427` for
`.claude-host` / `.gemini-host` / `.copilot-host`). There is no `:ro` repo
bind for any agent run, let alone an `enhance_issue`-specific one.

### R2 — runner-credential auth; no ANTHROPIC_API_KEY dependency (Phase 1) — NOT MET

The activity still calls the LLM directly, not through the containerized
runner-credential path:

- `app/temporal/activities/enhance_issue_activity.rb:186` —
  `response = AgentHarness.send_message(prompt, **llm_options(provider))`
- `app/temporal/activities/enhance_issue_activity.rb:213-223` — `llm_options`
  builds `{ provider:, timeout:, dangerous_mode: false, tools: :none }` and
  resolves the API key from the environment (the `ANTHROPIC_API_KEY`-from-ENV
  gap the RDR Problem Statement identifies).

This is precisely the credential bifurcation the RDR set out to close
(R7 / AE4). It is still open.

### R3 — codebase-grounded question generation (Phase 2) — NOT MET

The prompt carries only the issue text, conversation, and knowledge-base
retrieval results. It has no instruction to explore the repository and no
read-only statement, and the run has no container/repo access to act on one:

- `app/temporal/activities/enhance_issue_activity.rb:228-303` — `prompt_for`
  emits `## Repository`, `## Issue`, `## Conversation`, `## Retrieval Results`,
  and the context bundle only. No "read the repo", no "self-answer", no
  read-only guidance.

### R4 — codebase-grounded sufficiency re-evaluation (Phase 2) — NOT MET

The recheck loop queues the same non-container `enhance_issue` goal
(`app/temporal/workflows/git_hub_poll_workflow.rb:145-150`), so re-evaluation
runs the same direct-LLM, repo-blind path. The prior Q&A *is* visible
(comment admission, see R8), but sufficiency is still judged against the KB
snapshot rather than the codebase.

### R5 — preserved output contract — MET (vacuously)

The `<!-- paid:enhance-issue -->` marker, the `needs_input` /
clarifying-questions flow, the re-evaluation loop, and `enhance_issue_round`
accounting are unchanged — because nothing changed. The contract is preserved,
but not because the RDR shipped; it is preserved by the absence of any change.

### R6 — unchanged routing — MET (vacuously)

`analyze_issue` still routes `sufficient → create_pr`, `insufficient →
enhance_issue` (`app/temporal/workflows/agent_execution_workflow.rb:175`).
Unchanged, as the RDR requires — again vacuously, since the gate was never
altered.

### R7 — credential unification — NOT MET

See R2. The run is still on the ENV `ANTHROPIC_API_KEY` path; the DB-stored
runner credential is not injected for this goal.

### R8 — composes with #3235 (comment admission) — PARTIAL (prerequisite only)

The PR #3235 comment-admission work **is** present and correct, independent of
this RDR:

- `app/temporal/activities/enhance_issue_activity.rb:318-326` —
  `trusted_comments` re-admits Paid's own marker comments via
  `ClarifyingQuestions::CommentAdmission`.

That is the *prerequisite* the RDR builds on. But it currently composes with a
direct-LLM run, not a containerized re-evaluation, so the RDR's intent
(answers stay visible to a *containerized* re-evaluation run) is unrealized.

### AE1 — self-answer codebase-determinable questions — NOT MET

No repo access, no self-answering prompt instruction (see R3). The spec
(`spec/temporal/activities/enhance_issue_activity_spec.rb`) mocks
`AgentHarness::Response` / `send_message` and asserts comment shape; it has no
"does not ask codebase-answerable questions" scenario.

### AE2 — re-evaluation reads codebase + prior answers — NOT MET

Same non-container re-evaluation path (see R4). Prior answers are admitted
(R8), but the codebase is not read.

### AE3 — read-only: no file changes / commits — NOT MET (and untestable)

There is no container and no repo mount to enforce read-only against. The
run cannot modify files because it has no files.

### AE4 — succeeds with ANTHROPIC_API_KEY unset — NOT MET

The direct `send_message` call reads its key from ENV (see R2). With
`ANTHROPIC_API_KEY` unset and no runner credential injected, the call has no
key.

## Open Planning Questions — UNRESOLVED

Both deferred questions from the RDR remain open because the work that would
resolve them never landed:

1. **Workflow insertion point.** The RDR asked to confirm where to splice the
   container-provisioning steps. The code still short-circuits at
   `agent_execution_workflow.rb:151` — no insertion was made.
2. **Runner functioning under a read-only repo mount.** No read-only mount
   exists to validate any runner against.

## LID Coherence

`bin/coherence-check.mjs` is clean (exit 0). The `docs/intent/issue-enhancement/`
segment accurately reflects the **shipped** work — the clarifying-question
style, comment admission, and LID-aware prompt materialization
(ISSUE-ENHANCEMENT-001…005, all `[x]`, with matching `@spec` annotations in
`enhance_issue_activity.rb` and `build_for_issue.rb`).

The segment does **not** yet carry EARS claims for RDR-052's codebase-aware
execution model. That is correct: the LID arrow says intent flows HLD → LLD →
EARS → Tests → Code, and the implementation (Code) has not shipped, so there
is nothing for new EARS claims to trace to. Adding `[x]`-marked specs for a
containerized execution model that does not exist would be exactly the
"false-confidence" the testing rules warn against. The correct LID state while
the implementation is pending is the current one; new claims should be added
*with* the implementation in #3254 / #3255.

## Remaining Gaps (follow-up issues)

The gaps are the implementation itself, which is why this is filed as a
dependency-blocked closeout rather than a silent "Partially Implemented." Each
must be its own independently-pickable issue:

- **#3254 — Phase 1: wire `enhance_issue` into container provisioning
  (read-only).** Remove `enhance_issue` from `NON_CONTAINER_GOALS`
  (`create_agent_run_activity.rb:7`, `defaults.rb:220`); route it through
  provisioning instead of short-circuiting (`agent_execution_workflow.rb:151`);
  add a read-only repo bind alongside the existing writable state volumes;
  switch auth to the runner-credential path. Acceptance: AE3, AE4.
- **#3255 — Phase 2: codebase-grounded question generation + sufficiency
  re-evaluation.** Replace the direct-LLM `prompt_for` with a repo-exploration
  agent prompt (read-only stated); ground re-evaluation in the codebase + prior
  Q&A. Acceptance: AE1, AE2.
- **Deferred (out-of-scope per RDR-052):** `analyze_issue` shares the same
  `trusted_comments` bug and KB-blindness as `enhance_issue` (it is also a
  non-container goal). It only routes, so the impact is lower, but it should be
  a separate follow-up rather than folded into this RDR.

> Note: GitHub issue creation was not performed during this audit (no `gh`
> access in the audit environment). The dependency issues #3254 / #3255 are
> presumed to already exist as the implementation chain; the deferred
> `analyze_issue` follow-up should be filed when that work is scoped.

## Conclusion

RDR-052 remains **Draft**. The closeout is **blocked** on the unmerged
implementation chain (#3254, #3255). When both phases ship, re-open this
closeout: re-run the per-requirement check above, add the EARS claims for the
new execution model to `docs/intent/issue-enhancement/` alongside the code,
confirm `bin/coherence-check.mjs` is clean, and only then flip the RDR and
README index row to **Implemented**.
