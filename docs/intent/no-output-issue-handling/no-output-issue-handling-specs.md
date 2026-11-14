# EARS Specs: No-Output Issue Handling

> Testable claims for issue-scoped runs that finish without producing a pull
> request or commit. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r NO-OUTPUT-ISSUE-001`).

## Human-visible parked outcomes

- [x] **NO-OUTPUT-ISSUE-001** — When an issue-scoped no-output run parks the
  issue in `paid_state: "recommend_close"` or `paid_state: "needs_input"`,
  the system SHALL attempt to post the matching marker-tagged GitHub
  explanation comment. If GitHub rejects that comment attempt after the issue
  state transition, the system SHALL durably record the failure on the
  `AgentRun` and surface a user-visible error summary outside the log stream,
  so the parked issue never exists with neither a human rationale nor a
  surfaced error.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-002** — When the no-output handler is retried after a
  successful explanation comment already exists, the system SHALL detect the
  marker, SHALL NOT post a duplicate comment, and SHALL clear any previously
  recorded explanation-comment failure for that run.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

## Goal-aware classification for no-code-required completions

- [x] **NO-OUTPUT-ISSUE-003** — When an issue-scoped no-output run's agent
  output contains a `<!-- paid:no-code-required -->` declaration marker with a
  non-blank rationale fenced between `<!-- no-code-required-rationale-start
  -->` and `<!-- no-code-required-rationale-end -->`, the system SHALL
  classify the outcome as `no_code_required` — distinct from `recommend_close`
  — SHALL transition the issue to `paid_state: "completed"`, and SHALL post a
  marker-tagged GitHub comment surfacing the declared rationale for a human.
  This lets an umbrella, verification, or audit issue whose successful
  closeout requires no code change (e.g. #3441) complete honestly instead of
  being parked as `recommend_close`.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-004** — When an issue-scoped no-output run's agent
  output contains no no-code-required declaration marker, or the marker is
  present without a non-blank rationale block, the system SHALL classify the
  outcome using the existing `provider_error` / `infrastructure_error` /
  `needs_input` / `recommend_close` heuristics unchanged.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-005** — While classifying an issue-scoped no-output
  run, the system SHALL search for the no-code-required declaration across the
  same most-recent output window used for error classification, independently
  of the smaller output excerpt quoted in the GitHub comment, so a verbose run
  that emits the declaration outside the excerpt window is still classified
  `no_code_required`.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-006** — When a `no_code_required` outcome transitions
  an issue to `paid_state: "completed"`, the system SHALL also stamp
  `no_code_required_at` on the issue, permanently excluding it from Auto-Pick's
  completed-issue recovery path (see AUTO-PICK-QUEUE-004) so the agent's
  terminal declaration does not loop the issue back into the queue. An epic
  umbrella may re-enter only through AUTO-PICK-QUEUE-010 after newly linked
  required work resolves.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-008** — When an issue-scoped run has `iterations: 0`,
  the no-output classifier SHALL derive observable main-agent work from a
  successful or timed-out persisted `main_agent` runner attempt with nonzero recorded
  output, excluding smoke preflight and post-run commands. It SHALL permit that
  work to reach
  `recommend_close` or a valid `no_code_required` declaration, while explicit
  provider and infrastructure failure signals retain precedence and a
  smoke-only run remains an infrastructure failure.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/models/agent_run.rb`,
  `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-009** — When two automatic `create_pr` runs for the
  same issue and current closeout-evidence and intent revisions complete as
  `recommend_close` without a pull request or result commit, the system SHALL
  hold further automatic implementation admission and dequeue for that
  revision pair using the recorded run facts, SHALL retain the bounded run IDs
  and an operator next action in diagnostics, and SHALL release the hold only
  after relevant evidence or intent changes or an authorized explicit retry.
  A single no-progress outcome SHALL not hold the issue, and provider or
  transport failures SHALL continue through their typed retry policy.
  *Tests:* `spec/services/issues/no_progress_create_pr_hold_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/issues/no_progress_create_pr_hold.rb`,
  `app/temporal/activities/handle_no_output_issue_run_activity.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

## PR-producing partial closeouts

- [x] **NO-OUTPUT-ISSUE-007** — When a PR-producing run leaves an approved
  acceptance criterion unmet, the system SHALL use an agent-harness structured
  assessment and SHALL reconcile every gap to an existing open owner, a
  source-retained gap when the source itself owns the remaining work, a
  replay-safe focused follow-up with an explicit local and GitHub-visible
  dependency, or a blocking Inbox prerequisite for an authorized operator
  that states the gap's exact next step; an assessment whose human gap omits
  a nonblank next step SHALL be rejected before reconciliation persists it,
  so a retry regenerates the assessment instead of publishing a generic
  prerequisite. Both API and CLI requests SHALL explicitly supply the JSON
  response contract. Assessments SHALL allow 60 seconds for runner startup and
  generation within the enclosing activity's 120-second budget, leaving time
  for timeout cleanup and reconciliation.
  Malformed JSON SHALL fail closed without logging response excerpts.
  Unsuccessful transport responses SHALL surface a bounded, secret-redacted
  transport diagnostic distinct from invalid assessment data.
  The bounded owner list SHALL prioritize linked open issues and then recent
  eligible open issues, excluding issues whose dependency path already reaches
  the source. A
  source-retained gap SHALL keep the issue incomplete
  without creating another issue or a self-dependency. A closed historical
  issue or an untrusted author SHALL NOT satisfy ownership.
  GitHub failures SHALL retain durable retry state on the run. The
  reconciliation SHALL run before the parent issue is completed; while any
  gap remains outstanding, the parent SHALL stay incomplete, SHALL be
  dependency-blocked when an open owner is linked, and SHALL still receive the run's PR-link evidence as a
  comment on the parent issue (idempotent across retries), and SHALL NOT be
  transitioned to `paid_state: "completed"` by the run's closeout path.
  Once the partial PR is no longer open and any recorded gap-owner
  dependencies are satisfied, Auto-Pick SHALL re-admit the parent through a
  partial-closeout re-audit exception to the permanent merged-PR guard,
  keyed on the issue's latest PR-producing run; a later gap-free closeout
  SHALL restore the guard.
  *Tests:* `spec/services/partial_closeouts/reconcile_spec.rb`,
  `spec/services/llm/analyze_partial_closeout_spec.rb`,
  `spec/temporal/activities/reconcile_partial_closeout_activity_spec.rb`,
  `spec/temporal/activities/post_partial_closeout_evidence_activity_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/partial_closeouts/reconcile.rb`,
  `app/services/llm/analyze_partial_closeout.rb`,
  `app/temporal/activities/reconcile_partial_closeout_activity.rb`,
  `app/temporal/activities/post_partial_closeout_evidence_activity.rb`,
  `app/temporal/workflows/agent_execution_workflow.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.
