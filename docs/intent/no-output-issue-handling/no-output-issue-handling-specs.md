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
