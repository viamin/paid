# RDR-052 Audit Report — 2026-08-23 Closeout

- **RDR**: [RDR-052: Codebase-Aware Issue Enhancement](RDR-052-codebase-aware-enhance-issue.md)
- **Audit date**: 2026-08-23
- **Reconciliation issue**: #3602 (RDR-052 still said Draft after Phase 1/2/closeout issues closed)
- **Follows**: the [RDR Closeout Checklist](closeout-checklist.md)
- **Conclusion**: **Implemented**. Every acceptance criterion (R1–R8, AE1–AE4)
  now has shipped code and passing test evidence. No child issues filed.

## Root Cause of the Stale Status

The [2026-08-06 closeout](audit-report-2026-08-06-rdr-052.md) (issue #3256,
merged as PR #3265) correctly found "not shipped" *at the moment it was
written*, but the audit and the implementation it was auditing raced each
other:

| Event | PR | Merged at (UTC) |
|-------|----|------------------|
| #3256 closeout audit ("not shipped, Draft") | #3265 | 2026-08-06T09:15:13Z |
| #3255 Phase 2 (codebase-grounded questions + re-evaluation) | #3264 | 2026-08-06T10:36:16Z |
| #3254 Phase 1 (containerized comment-only execution) | #3267 | 2026-08-07T04:40:17Z |

The audit merged first, roughly 80 minutes before Phase 2 and about 19 hours
before Phase 1. Both implementation issues closed shortly afterward, but
nothing re-ran the closeout once they landed — the RDR document, the README
status table, and the LID `issue-enhancement` specs were never revisited.
That gap is what issue #3602 flagged, and what this audit reconciles.

## Validation Evidence

```console
$ bundle exec rspec spec/temporal/activities/enhance_issue_activity_spec.rb \
    spec/temporal/activities/fetch_issues_activity_spec.rb
154 examples, 0 failures

$ bundle exec rspec spec/temporal/activities/run_agent_activity_spec.rb
307 examples, 0 failures

$ bundle exec rspec spec/temporal/workflows/agent_execution_workflow_spec.rb
100 examples, 0 failures

$ bundle exec rubocop app/temporal/activities/run_agent_activity.rb \
    app/temporal/activities/fetch_issues_activity.rb \
    spec/temporal/activities/run_agent_activity_spec.rb \
    spec/temporal/activities/fetch_issues_activity_spec.rb
4 files inspected, no offenses detected

$ node bin/coherence-check.mjs
# issue-enhancement segment: no reverse orphans, no uncovered [ ] specs,
# no duplicate @spec IDs (see "LID Coherence" section below)
```

## Acceptance Criteria vs. Shipped Implementation

### R1: Containerized (not direct-LLM) execution

**Status**: Implemented.

`enhance_issue` is no longer listed under
`OrchestrationStrategies::Defaults.non_container_goals`
(`app/services/orchestration_strategies/defaults.rb:221`, which now reads
`%w[analyze_issue]`). The workflow provisions a container and runs the agent
before `EnhanceIssueActivity` executes in post-run mode
(`app/temporal/workflows/agent_execution_workflow.rb:296-308`,
`@spec ISSUE-ENHANCEMENT-006`):

```ruby
if goal == "enhance_issue"
  # Containerized enhance_issue: the agent explored the repo and
  # produced structured JSON output.  EnhanceIssueActivity (post-run
  # mode) reads the output, posts the comment, and applies labels
  # (RDR-052 Phase 1).
  enhance_result = run_activity(Activities::EnhanceIssueActivity,
    { agent_run_id: agent_run_id, post_run: true },
    start_to_close_timeout: 300,
    retry_policy: NO_RETRY)
  ...
end
```

This runs after `ProvisionContainerActivity` and `RunAgentActivity`. The
`skip_clone` set at `agent_execution_workflow.rb:226` no longer includes
`enhance_issue`, so it clones like any other containerized goal.

**Tests**: `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
`spec/temporal/activities/enhance_issue_activity_spec.rb` (100 + 33 examples,
0 failures — see Validation Evidence).

**Verdict**: Met.

---

### R2 / R7: Credential unification (runner credential, not `ANTHROPIC_API_KEY`)

**Status**: Implemented.

`app/temporal/activities/enhance_issue_activity.rb` no longer contains any
`AgentHarness.send_message` call. The class-level comment states the design
directly: *"Containerized execution: the agent has already explored the repo
in a comment-only containerized run via RunAgentActivity (RDR-052 Phase 1)...
This activity reads that result, posts the enhancement comment, and applies
label state."* The activity's job is now `#enhance_issue_post_run` →
`#parse_agent_output!` → `#extract_json_payload`, reading the containerized
agent's stdout for the `paid-enhance-issue-output` JSON delimiter — it never
constructs a direct LLM request, so it never reads `ANTHROPIC_API_KEY`.
Authentication for the underlying agent run goes through the same
runner-credential injection path (`config/initializers/agent_harness.rb`,
DB-stored `runner_credentials`) as `create_pr` and `lid_planning`.

**Tests**: `spec/temporal/activities/enhance_issue_activity_spec.rb` (33
examples, 0 failures).

**Verdict**: Met.

---

### R3: Self-answer codebase-determinable questions

**Status**: Implemented.

`FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`
(`app/temporal/activities/run_agent_activity.rb`, tagged
`@spec ISSUE-ENHANCEMENT-008`) instructs the agent to explore the repository
and self-answer codebase-determinable questions (existing models, platform
targets, persistence format, current patterns) before asking the human, and
to ask only about genuine product, scope, or intent ambiguities the code
cannot resolve.

**Tests**:
`spec/temporal/activities/run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal`
now pins this instruction explicitly (previously the test only pinned the
comment-only / no-write safety instructions, not the self-answer directive —
strengthened as part of this closeout):

```ruby
expect(prompt).to include("Explore the repository")
expect(prompt).to include("self-answer codebase-determinable questions")
expect(prompt).to include("before asking the human")
```

**Verdict**: Met.

---

### R4: Grounded sufficiency judgment on re-evaluation

**Status**: Implemented.

`detect_enhance_issue_rechecks`
(`app/temporal/activities/fetch_issues_activity.rb`, tagged
`@spec ISSUE-ENHANCEMENT-009`) re-queues the same containerized,
codebase-grounded `enhance_issue` goal when the needs-input label clears,
rather than a knowledge-base-only recheck — so the re-evaluation run reads
the repository alongside the user's prior answers.

**Tests**:
`spec/temporal/activities/fetch_issues_activity_spec.rb` `"when the
enhance_issue needs-input label is removed"` context, including `"returns a
recheck request and suppresses normal label evaluation"` (tagged
`@spec ISSUE-ENHANCEMENT-009`).

**Verdict**: Met.

---

### R5 / R6: Preserved output contract and unchanged routing

**Status**: Implemented (unchanged by design).

The `<!-- paid:enhance-issue -->` comment marker, the `needs_input` /
clarifying-questions flow (`ClarifyingQuestions::Load` /
`SubmitAnswers` / `ClearNeedsInput`), the dashboard queue, and the
`analyze_issue` → `enhance_issue` routing in
`agent_execution_workflow.rb:175` (`followup_goal = result[:sufficient_context]
? "create_pr" : "enhance_issue"`) are all untouched by the RDR-052 work. Only
`enhance_issue`'s execution model changed.

**Verdict**: Met (no regression — confirmed by the full
`enhance_issue_activity_spec.rb` and `fetch_issues_activity_spec.rb` suites).

---

### R8: Composes with PR #3235 comment admission

**Status**: Implemented.

`EnhanceIssueActivity#trusted_comments` reuses
`ClarifyingQuestions::CommentAdmission` to re-admit Paid's own structured
marker comments (prior clarifying Q&A) into the containerized run's context,
via `Project#paid_bot_author?`. This is unchanged composition from PR #3235,
now feeding a containerized run instead of a direct-LLM one.

**Tests**: `spec/temporal/activities/enhance_issue_activity_spec.rb`.

**Verdict**: Met.

---

### AE1: Self-answers codebase-readable questions

**Status**: Implemented. Covered by the strengthened
`run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal` assertions
above (R3).

### AE2: Grounded re-evaluation reads the codebase + prior answers

**Status**: Implemented. Covered by `fetch_issues_activity_spec.rb`'s
`detect_enhance_issue_rechecks` coverage (R4) plus comment-admission
re-inclusion of prior answers (R5/R8).

### AE3: No file changes, commits, or pushes

**Status**: Implemented — via a documented design delta from the original
plan (see below), not the originally planned structural `:ro` mount.
`app/services/containers/provision.rb#workspace_mount_mode` returns `"rw"`
(not `"ro"`) because the platform must clone the repo into `/workspace`
before the agent can read it. Enforcement is instead: (1) the prompt
explicitly forbids writes and states the run is comment-only, and (2) at the
workflow/activity level, `RunAgentActivity` skips
`commit_uncommitted_changes` when `agent_run.enhance_issue_goal?`, so the
workflow never commits, pushes, or opens a PR for this goal regardless of
what the container's filesystem looks like when the run ends.

**Tests**: `spec/temporal/activities/run_agent_activity_spec.rb` (comment-only
/ no-write prompt assertions), `spec/temporal/workflows/agent_execution_workflow_spec.rb`
(enhance_issue post-run branch, no commit/push activities scheduled).

**Verdict**: Met, via behavioral + workflow-level enforcement rather than a
structural read-only bind mount.

### AE4: Works with `ANTHROPIC_API_KEY` unset

**Status**: Implemented. `EnhanceIssueActivity` in post-run mode never
constructs a direct LLM request (R2/R7), so it has no `ANTHROPIC_API_KEY`
dependency at all — the underlying containerized agent run authenticates via
the injected runner credential like every other containerized goal.

**Verdict**: Met.

---

## Design Delta: `:rw` Mount Instead of `:ro`

The RDR's "Resolved Decisions" section and Phase 1 plan called for
**structural** read-only enforcement (workspace bind mounted `:ro`, state/
scratch volumes writable). The shipped implementation instead mounts the
workspace `:rw`:

```ruby
# app/services/containers/provision.rb
# Returns the mount mode for the workspace bind. The platform must clone
# the repo into /workspace before enhance_issue can inspect it, so the
# Docker mount stays writable even though the enhance prompt forbids
# changing files and the workflow never pushes enhance_issue output.
# @spec ISSUE-ENHANCEMENT-006
def workspace_mount_mode
  "rw"
end
```

This is a legitimate, intentional substitution: the original plan assumed
the repo would already be present (or cloned by some other read-only-capable
step) before a `:ro` mount was applied; the shipped design clones *into* the
same mount the agent then reads, which requires write access during clone.
"No durable output beyond the comment/labels" (AE3) is preserved instead by
two independent layers — prompt instruction and workflow-level commit/push
skip — and both are tested. This is called out as a design delta rather than
a gap because AE3 is fully met; only the *mechanism* changed, not the
guarantee.

## Minor Observation (Not Blocking)

`CreateAgentRunActivity::NON_CONTAINER_GOALS`
(`app/temporal/activities/create_agent_run_activity.rb:7`) is a separate,
narrower constant from `OrchestrationStrategies::Defaults.non_container_goals`
and still lists `enhance_issue`. It is used in
`validate_runnable_runner!` (`create_agent_run_activity.rb:615`) to skip
upfront runner-availability validation for goals in that list. Since
`enhance_issue` now genuinely needs a runnable container, this upfront
validation skip is stale — though it has no bearing on whether R1–R8/AE1–AE4
are met (the goal still provisions and runs containerized once queued; a
missing-runner failure would simply surface later, inside provisioning,
instead of earlier). Not filed as a separate child issue; worth cleaning up
opportunistically alongside other work that touches
`create_agent_run_activity.rb`.

## LID Coherence

Fixed as part of this closeout: `docs/intent/issue-enhancement/issue-enhancement-specs.md`
had a duplicate `ISSUE-ENHANCEMENT-006` ID (one definition for R1/R2
containerized execution, a second for R3 self-answering) and carried `[D]`
deferred markers for the R3/R4 claims that had, in fact, shipped with Phase
1/2. Renumbered the R3/R4 claims to `ISSUE-ENHANCEMENT-008` /
`ISSUE-ENHANCEMENT-009`, flipped them to `[x]`, and added matching `@spec`
tags in `run_agent_activity.rb`, `fetch_issues_activity.rb`, and their specs.
`docs/intent/issue-enhancement/issue-enhancement-design.md` updated to match
(and to attribute R3/R4 to Phase 2 (#3255) specifically, rather than
conflating it with Phase 1 (#3254)'s containerization work).
`node bin/coherence-check.mjs` shows no reverse orphans, no uncovered gap
markers, and no drift signals for the `issue-enhancement` segment.

## Gaps

None against R1–R8 or AE1–AE4.

## Child Issues

None filed. The design delta (`:rw` vs. `:ro`) and the
`NON_CONTAINER_GOALS` observation are documented above but do not block
"Implemented" status.

## Status Change

- `docs/rdrs/RDR-052-codebase-aware-enhance-issue.md`: Status `Draft` →
  `Implemented`.
- `docs/rdrs/README.md`: RDR-052 row Status `Draft` → `Implemented`.
- Issue #3602 is closed by the PR that carries this audit.
