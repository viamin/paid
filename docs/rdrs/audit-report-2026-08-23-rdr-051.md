# RDR-051 Audit Report — 2026-08-23 Closeout

- **RDR**: [RDR-051: Linked-Intent Development (LID) Integration](RDR-051-lid-aware-agent-runs.md)
- **Audit date**: 2026-08-23
- **Closeout issue**: #3598 (final validation closeout for LID-aware agent runs)
- **Follows**: the [RDR Closeout Checklist](closeout-checklist.md)
- **Conclusion**: **Implemented**. Every shipped acceptance claim for the
  LID-aware run surface now has code and test evidence. No child issues filed.

## Why The RDR Was Still Partial

The RDR document and the `lid-aware-agent-runs` LLD were left in a stale
"partially implemented" state after the reconciliation follow-ups landed. The
backing EARS segment had already been updated to mark `LID-RUNS-001` through
`LID-RUNS-007` implemented, but the RDR status, README index row, and LLD
closeout note were never reconciled against the shipped code.

This audit re-ran the closeout against the codebase itself rather than treating
closed follow-up issues (#3198, #3199, #3200, #3201) as evidence.

## Validation Evidence

```console
$ export DB_HOST=paid-svc-a3-s1-postgres DB_USERNAME=agent DB_PASSWORD=agent DB_PORT=5432
$ bin/rails db:prepare
# completed successfully

$ node bin/coherence-check.mjs
# exited 0; repo-wide drift remains outside RDR-051:
#   Reverse orphans (5), Uncovered [ ] specs (6),
#   plus broader untagged-file drift

$ bundle exec rubocop
3077 files inspected, no offenses detected

$ bundle exec rspec
Finished in 33 minutes 52 seconds
20289 examples, 0 failures, 7 pending
```

## Acceptance Criteria Vs. Shipped Implementation

### LID-RUNS-001: LID-aware implementation prompt contract

**Status**: Implemented.

`Lid::InjectIntoPrompt` appends the arrow-walking workflow section for LID
projects, including HLD/LLD/EARS reading, tests-first, `@spec` annotations,
coherence-check execution, and elicited-intent materialization guidance
(`app/services/lid/inject_into_prompt.rb:5-18`, `:73-158`).

**Tests**: `spec/services/lid/inject_into_prompt_spec.rb:22-33`,
`:54-137`.

**Verdict**: Met.

---

### LID-RUNS-002: `lid_planning` run creation and `plan_doc_source`

**Status**: Implemented.

`ProjectsController#start_lid` creates a queued manual `lid_planning` run and
persists the optional `plan_doc_source`
(`app/controllers/projects_controller.rb:240-288`). `AgentRun#prompt_for_lid_planning`
passes the stored plan docs into `Prompts::BuildForLidPlanning`
(`app/models/agent_run.rb:3349-3362`).

**Tests**: `spec/requests/projects_spec.rb:3129-3148`.

**Verdict**: Met.

---

### LID-aware issue enhancement materialization

**Status**: Implemented.

Trusted clarifying answers are promoted to `# Elicited Intent` for LID-enabled
implementation prompts, and the prompt section explicitly instructs the agent
to carry those answers into LLD/EARS updates before or alongside code changes
(`app/services/prompt_assembly/sections/clarified_requirements.rb:3-19`,
`:46-59`).

**Tests**: `spec/services/prompts/build_for_issue_spec.rb:166-179`.

**Verdict**: Met.

---

### LID-RUNS-003: Coherence persistence and PR soft-block surfacing

**Status**: Implemented.

`Lid::CoherenceCheck` runs for `create_pr`, `review`, and `lid_planning`,
persists the parsed report on `agent_run.external_metadata`, and logs failed
findings as soft-blocks (`app/services/lid/coherence_check.rb:5-38`,
`:97-119`). `CreatePullRequestActivity` includes those failed findings in the
PR body instead of discarding them
(`spec/temporal/activities/create_pull_request_activity_spec.rb:207-226`).

**Tests**: `spec/services/lid/coherence_check_spec.rb:23-40`,
`spec/temporal/activities/create_pull_request_activity_spec.rb:207-226`.

**Verdict**: Met.

---

### LID-RUNS-004: Planning-PR review correction loop

**Status**: Implemented.

`AgentRun.planning_run_for_pr` identifies the `lid_planning` run that opened a
Planning PR (`app/models/agent_run.rb:1607-1617`), and
`Prompts::BuildForPr` switches review-goal runs into the Planning-PR
intent-correction prompt path when unresolved review threads target inferred
design decisions (`app/services/prompts/build_for_pr.rb:124-136`, `:564-599`).

**Tests**: `spec/services/prompts/build_for_pr_spec.rb:690-760`.

**Verdict**: Met.

---

### LID-RUNS-005: Named plan docs are authored intent

**Status**: Implemented.

`Prompts::BuildForLidPlanning` treats named plan docs as authored intent,
maps them into HLD/LLD/EARS, and explicitly forbids `[inferred]` markers for
plan-doc-sourced rationale (`app/services/prompts/build_for_lid_planning.rb:54-122`).

**Tests**: `spec/services/prompts/build_for_lid_planning_spec.rb:16-39`,
`:56-92`.

**Verdict**: Met.

---

### LID-RUNS-006: External-agent LID contract

**Status**: Implemented.

`Interop::ExternalAgentLidContract` exposes the effective `lid_mode`, detection
metadata, rendered implementation prompt contract, and `lid_planning` support
to external callers (`app/services/interop/external_agent_lid_contract.rb:5-60`).
The MCP `get_project` tool returns the same contract surface
(`app/mcp/tools/get_project.rb:23-39`).

**Tests**: `spec/requests/project_interoperability_spec.rb:239-259`,
`spec/mcp/tools/get_project_spec.rb:46-60`.

**Verdict**: Met.

---

### LID-RUNS-007: Positive `lid_planning` output contract

**Status**: Implemented.

`Lid::PlanningContract` validates the required artifact set separately for
adoption versus refinement runs (`app/services/lid/planning_contract.rb:21-96`).
`CreatePullRequestActivity` enforces both the docs-only allowlist and the
positive output contract before a Planning PR can be opened
(`app/temporal/activities/create_pull_request_activity.rb:666-725`).

**Tests**: `spec/services/lid/planning_contract_spec.rb:11-108`,
`spec/temporal/activities/create_pull_request_activity_spec.rb:791-844`.

**Verdict**: Met.

## Remaining Scope

None against RDR-051's shipped acceptance criteria.

The repo-wide coherence checker still reports unrelated global drift
(reverse-orphan `@spec` references, uncovered `[ ]` specs, and broad untagged
file counts), but those findings are not specific to the `lid-aware-agent-runs`
segment and do not reopen this RDR's closeout.

## Final Status

**Implemented**. The RDR, README index row, and `docs/intent/lid-aware-agent-runs/`
segment should all reflect implemented status after this closeout.
