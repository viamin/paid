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
