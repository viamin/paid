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

## Gap-blocked follow-up outcome

- [x] **NO-OUTPUT-ISSUE-003** — When an issue-scoped no-output run emits a
  complete follow-up marker plan (`followup-title`, `followup-body-start`,
  `followup-body-end`) and the run otherwise qualifies for a human-actionable
  no-output outcome, the system SHALL classify the run as `blocked_on_gap`,
  SHALL create one same-project follow-up issue from that marker content, SHALL
  append an explicit dependency declaration on the created issue to the parent
  issue, and SHALL return the parent to `paid_state: "new"` while leaving the
  new dependency as the only gate on auto-pick eligibility.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-004** — When the follow-up marker channel is missing,
  malformed, or partial, the system SHALL NOT create a follow-up issue and
  SHALL preserve the existing default classification behavior (`recommend_close`
  for otherwise-qualifying work-producing no-output runs).
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.

- [x] **NO-OUTPUT-ISSUE-005** — When a `blocked_on_gap` run is retried or emits
  repeated follow-up marker blocks, the system SHALL cap follow-up creation to
  one issue per run, SHALL deduplicate against existing open same-project issues
  by the persisted follow-up title, SHALL avoid duplicating the parent's
  dependency line, and SHALL record the follow-up creation or reuse in the
  account audit trail.
  *Tests:* `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `app/temporal/activities/handle_no_output_issue_run_activity.rb`.
