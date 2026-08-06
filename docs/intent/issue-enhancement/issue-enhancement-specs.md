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
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#prompt_for`,
  `app/services/clarifying_questions/load.rb`.

- [x] **ISSUE-ENHANCEMENT-006** — When generating clarifying questions, the
  system SHALL ground question-generation in the actual repository: it SHALL
  self-answer codebase-determinable questions (existing models, platform
  targets, persistence format, current patterns) from the code and SHALL NOT
  ask the human clarifying questions whose answers are directly readable from
  the repository, asking only about genuine product, scope, or intent
  ambiguities the code cannot resolve (RDR-052 R3).
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#grounding_instructions`.

- [x] **ISSUE-ENHANCEMENT-005** — When issue enhancement re-evaluates an issue
  after the user answers clarifying questions, the system SHALL include the
  prior clarifying questions and answers in the conversation context supplied
  to the LLM, even though those comments are authored by the project's GitHub
  App bot (which the human-only comment trust filter deliberately excludes).
  The system SHALL re-admit only Paid's own structured marker comments via
  comment admission, never arbitrary bot comments, so the re-evaluation
  considers already-provided answers rather than re-asking them.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#trusted_comments`,
  `app/services/clarifying_questions/comment_admission.rb`,
  `app/models/project.rb#paid_bot_author?`.

- [x] **ISSUE-ENHANCEMENT-007** — When re-evaluating an issue after the user
  answers clarifying questions, the system SHALL judge answer-sufficiency
  against the user's answers TOGETHER WITH the actual codebase it reads, not
  against the supplied knowledge-base context alone, so the readiness verdict
  is grounded in the real code (RDR-052 R4).
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#reevaluation_guidance`.

## LID-aware prompt materialization

- [x] **ISSUE-ENHANCEMENT-003** — When a project is marked with a non-empty
  `lid_mode` and the issue has answered clarifying questions, the system SHALL
  surface those answers into the `create_pr` issue prompt as elicited intent
  and instruct the implementation run to draft or update the relevant LLD and
  EARS artifacts from that confirmed human intent before or alongside code
  changes.
  *Tests:* `spec/services/prompts/build_for_issue_spec.rb`.
  *Code:* `app/services/prompts/build_for_issue.rb#clarifying_answers_section`.

- [x] **ISSUE-ENHANCEMENT-004** — When a project is not marked with `lid_mode`,
  the system SHALL omit the elicited-intent section even if answered
  clarifying-question comments exist.
  *Tests:* `spec/services/prompts/build_for_issue_spec.rb`.
  *Code:* `app/services/prompts/build_for_issue.rb#lid_enabled?`.
