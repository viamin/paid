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

- [D] **ISSUE-ENHANCEMENT-006** — When generating clarifying questions, the
  system SHALL ground question-generation in the actual repository: it SHALL
  self-answer codebase-determinable questions (existing models, platform
  targets, persistence format, current patterns) from the code and SHALL NOT
  ask the human clarifying questions whose answers are directly readable from
  the repository, asking only about genuine product, scope, or intent
  ambiguities the code cannot resolve (RDR-052 R3).
  *Deferred:* Requires the read-only containerized execution path that lands
  with RDR-052 Phase 1 (#3254). Today `enhance_issue` is a direct LLM call
  (`tools: :none`, `enhance_issue` in `skip_clone` at
  `app/temporal/workflows/agent_execution_workflow.rb:234`) with no
  repository access; the prompt is grounded in the supplied retrieval
  results and knowledge-base context only. Restored when the agent has
  actual filesystem / repo access.

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

- [D] **ISSUE-ENHANCEMENT-007** — When re-evaluating an issue after the user
  answers clarifying questions, the system SHALL judge answer-sufficiency
  against the user's answers TOGETHER WITH the actual codebase it reads, not
  against the supplied knowledge-base context alone, so the readiness verdict
  is grounded in the real code (RDR-052 R4).
  *Deferred:* Same dependency as ISSUE-ENHANCEMENT-006 — the agent has no
  repository access until #3254 lands. Today the re-evaluation prompt
  instructs the agent to weigh the user's answers against the supplied
  knowledge-base context, which is the strongest grounding available
  pre-Phase 1.

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
