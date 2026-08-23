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
  If a containerized enhancement agent posts a Paid-authored clarifying-question
  comment directly but fails to emit parseable structured output, the system
  SHALL recover only when it can parse and persist the questions, then apply the
  enhance-issue needs-input label and move the issue to `paid_state:
  "needs_input"` rather than leaving it auto-pick eligible. If recovery is not
  possible, the run SHALL still fail non-retryably but the issue SHALL move to
  `paid_state: "needs_input"` so automatic picking does not loop on the same
  malformed enhancement attempt.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#enhance_issue_post_run`,
  `app/temporal/activities/enhance_issue_activity.rb#recover_paid_question_comment!`,
  `app/services/clarifying_questions/load.rb`.

- [x] **ISSUE-ENHANCEMENT-008** — When generating clarifying questions, the
  system SHALL ground question-generation in the actual repository: it SHALL
  self-answer codebase-determinable questions (existing models, platform
  targets, persistence format, current patterns) from the code and SHALL NOT
  ask the human clarifying questions whose answers are directly readable from
  the repository, asking only about genuine product, scope, or intent
  ambiguities the code cannot resolve (RDR-052 R3).
  *Tests:* `spec/temporal/activities/run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal`.
  *Code:* `app/temporal/activities/run_agent_activity.rb#FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`,
  `app/temporal/activities/run_agent_activity.rb#augment_prompt_for_enhance_issue_goal`.
  Shipped with RDR-052 Phase 1/2 (#3254, #3255): the run is now a
  containerized agent with repository access, and the prompt instructs it to
  explore the repo and self-answer before asking the human.

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

- [x] **ISSUE-ENHANCEMENT-009** — When re-evaluating an issue after the user
  answers clarifying questions, the system SHALL judge answer-sufficiency
  against the user's answers TOGETHER WITH the actual codebase it reads, not
  against the supplied knowledge-base context alone, so the readiness verdict
  is grounded in the real code (RDR-052 R4).
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`
  (`"when the enhance_issue needs-input label is removed"`).
  *Code:* `app/temporal/activities/fetch_issues_activity.rb#detect_enhance_issue_rechecks`,
  `app/temporal/activities/run_agent_activity.rb#FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`.
  Shipped with RDR-052 Phase 1/2 (#3254, #3255): re-evaluation re-queues the
  same containerized, codebase-grounded `enhance_issue` goal rather than a
  KB-only re-check, so the verdict reads the repo alongside the prior
  answers (admitted via ISSUE-ENHANCEMENT-005).

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

## Containerized read-only execution (RDR-052)

- [x] **ISSUE-ENHANCEMENT-006** — When issue enhancement runs, the system SHALL
  execute it as a containerized agent with repository access, authenticating
  via the injected runner credential instead of the `ANTHROPIC_API_KEY`
  environment variable. The agent prompt SHALL instruct the agent that the run
  is comment-only: workspace modifications are discarded and the agent SHALL
  NOT commit, push, or create a pull request. The workflow SHALL post the
  `<!-- paid:enhance-issue -->` comment and label state without committing,
  pushing, or creating a pull request.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#enhance_issue_post_run`,
  `app/temporal/workflows/agent_execution_workflow.rb`,
  `app/services/containers/provision.rb#workspace_mount_mode`,
  `app/services/orchestration_strategies/defaults.rb#non_container_goals`.
