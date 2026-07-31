# EARS Specs: Issue Enhancement

> Testable claims for the `enhance_issue` goal. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code.

## Clarifying-question flow

- [x] **ISSUE-ENHANCEMENT-001** — When issue enhancement determines that an
  issue lacks implementation-ready context, the system SHALL ask clarifying
  questions in plain language about the problem, desired behavior, constraints,
  alternatives, scope boundaries, and done criteria, without introducing LID
  jargon.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#prompt_for`.

- [x] **ISSUE-ENHANCEMENT-002** — When issue enhancement asks clarifying
  questions, the system SHALL continue using the existing enhancement comment
  marker and `needs_input` flow rather than creating a new state or surface.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#complete_with_questions`,
  `app/services/clarifying_questions/load.rb`.

## LID-aware prompt materialization

- [x] **ISSUE-ENHANCEMENT-003** — When a project is marked with a non-empty
  `lid_mode` and the issue has answered clarifying questions, the system SHALL
  surface those answers into the `create_pr` issue prompt as elicited intent.
  *Tests:* `spec/services/prompts/build_for_issue_spec.rb`.
  *Code:* `app/services/prompts/build_for_issue.rb#elicited_intent_section`.

- [x] **ISSUE-ENHANCEMENT-004** — When a project is not marked with `lid_mode`,
  the system SHALL omit the elicited-intent section even if answered
  clarifying-question comments exist.
  *Tests:* `spec/services/prompts/build_for_issue_spec.rb`.
  *Code:* `app/services/prompts/build_for_issue.rb#lid_enabled?`.
