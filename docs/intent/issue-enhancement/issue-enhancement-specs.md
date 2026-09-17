# EARS Specs: Issue Enhancement

> Testable claims for the `enhance_issue` goal. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code.

## Clarifying-question flow

- [x] **ISSUE-ENHANCEMENT-001** — When issue enhancement determines that an
  issue lacks implementation-ready context, the system SHALL ask clarifying
  questions in plain language about the problem, desired behavior, constraints,
  alternatives, scope boundaries, and done criteria, without introducing LID
  jargon. The system SHALL also instruct the agent to write the enhancement
  comment and its clarifying questions in simplified technical English: short
  sentences with one idea per sentence, plain technical words, no nested
  clauses or stacked jargon, while keeping technical meaning precise (#3840).
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal`,
  `spec/models/agent_run_spec.rb#prompt_for_goal`,
  `spec/migrations/sync_enhance_issue_prompt_simplified_english_spec.rb`.
  *Code:* `app/models/agent_run.rb#prompt_for_enhance_issue`,
  `app/temporal/activities/run_agent_activity.rb#FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`,
  `db/seeds/prompts.rb`,
  `db/migrate/20260916153929_sync_enhance_issue_prompt_simplified_english.rb`.

- [x] **ISSUE-ENHANCEMENT-002** — When issue enhancement asks clarifying
  questions, the system SHALL continue using the existing enhancement comment
  marker and `needs_input` flow rather than creating a new state or surface.
  If a containerized enhancement agent posts a Paid-authored clarifying-question
  comment directly but fails to emit parseable structured output, the system
  SHALL recover only when it can parse and persist the questions, then apply the
  enhance-issue needs-input label and move the issue to `paid_state:
  "needs_input"` rather than leaving it auto-pick eligible. If recovery is not
  possible, the run SHALL still fail non-retryably but the issue SHALL move to
  `paid_state: "manual_review"` so automatic picking does not loop on the same
  malformed enhancement attempt. Generic workflow failure handling SHALL NOT
  overwrite this terminal containment state with `paid_state: "failed"`, and
  questionless-`needs_input` repair SHALL NOT alter it.
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

- [x] **ISSUE-ENHANCEMENT-014** — When issue enhancement asks clarifying
  questions, the system SHALL require every question to stand on its own so a
  reader without deep project knowledge can understand and answer it. Each
  question SHALL open with one or two sentences of background explaining why
  the agent is asking and what it found in the repository, SHALL reference the
  relevant code, issue, or doc when one exists, SHALL name the options being
  asked about when the question could be read more than one way, and SHALL
  note where the issue fits in the roadmap (dependencies, follow-up work)
  when it affects the answer (#3841).
  *Tests:* `spec/models/agent_run_spec.rb#prompt_for_enhance_issue`,
  `spec/temporal/activities/run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal`,
  `spec/db/prompt_seeds_spec.rb` (`goal.enhance_issue self-contained questions coupling`),
  `spec/migrations/sync_enhance_issue_contextual_questions_prompt_spec.rb`.
  *Code:* `app/models/agent_run.rb#prompt_for_enhance_issue`,
  `app/temporal/activities/run_agent_activity.rb#FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`,
  `db/seeds/prompts.rb` (`goal.enhance_issue`),
  enhancement question-context prompt synchronization migration.

- [x] **ISSUE-ENHANCEMENT-018** — When a clarifying question has a short,
  enumerable set of answers, the `goal.enhance_issue` prompt SHALL instruct
  the agent to opt the question into choice semantics with strict sub-list
  option markers — `- ( ) Label) description` lines for single-answer
  questions, `- [ ]` / `- [x]` checkbox-family lines for multi-answer
  questions — instead of naming the options in prose (#3893). The seeded
  template, the code fallback in `RunAgentActivity`, and the prompt-sync
  migration SHALL carry the same option-syntax instructions. On the reader
  side, `ClarifyingQuestions::Choices` SHALL parse those markers — and only
  those markers — from a single folded question string, returning
  `{ type: :single | :multi, options: [{ label:, text: }] }` for a
  well-formed choice question with at least two options, and `nil` for
  prose questions, context bullets, mixed marker families, malformed
  options, or partial marker sets, so unmarked questions stay free text.
  Question strings SHALL remain byte-identical — `ClarifyingQuestions::Parse`
  is untouched and choices are a view-time attribute only (UI rendering is
  a follow-up issue).
  *Tests:* `spec/services/clarifying_questions/choices_spec.rb`,
  `spec/migrations/sync_enhance_issue_choice_markers_prompt_spec.rb`,
  `spec/db/prompt_seeds_spec.rb`
  (`goal.enhance_issue choice-marker coupling`),
  `spec/temporal/activities/run_agent_activity_spec.rb#augment_prompt_for_enhance_issue_goal`.
  *Code:* `app/services/clarifying_questions/choices.rb`,
  `app/temporal/activities/run_agent_activity.rb#FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT`,
  `db/seeds/prompts.rb` (`goal.enhance_issue`),
  `db/migrate/*_sync_enhance_issue_choice_markers_prompt.rb`.

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
  NOT commit, push, create a pull request, or post a GitHub comment. The GitHub
  proxy SHALL reject mutation requests and restrict reads from an
  `enhance_issue` run to its associated issue's detail endpoint; only comments
  admitted by Paid's trusted-comment filter SHALL reach the agent through its
  base prompt, and unrelated issue bodies SHALL NOT bypass that boundary. After
  validating the agent's delimited structured output, the workflow SHALL post
  the `<!-- paid:enhance-issue -->` comment and label state without committing,
  pushing, or creating a pull request. Structured runners (e.g. OpenCode,
  Codex) MAY wrap the agent's final message inside a JSONL transcript, where
  the delimiter's newlines are escaped within a JSON string field and the
  runner's own turn-selection logic MAY prefer an earlier progress message
  over the true final one. Extraction SHALL decode each transcript event's
  own message text and select the last delimiter match found across the
  transcript, rather than depending on the runner-selected "final" message.
  When the parse path fails even though the raw output demonstrably
  contained a delimited payload that satisfies the structured-output
  contract — i.e. Paid discarded a valid payload — the run SHALL still
  fail non-retryably and move the issue to `manual_review`
  (ISSUE-ENHANCEMENT-002), but SHALL refund the enhancement round consumed
  at queue time (ISSUE-ENHANCEMENT-011) — which only automatic runs
  consume, so manual runs SHALL NOT refund a round — so a Paid-side
  extraction defect does not burn round budget meant to bound repeated
  automatic re-evaluation. A delimited payload that is itself malformed
  JSON or omits the required keys is an agent contract failure, not an
  extraction defect, and SHALL consume the round.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#enhance_issue_post_run`,
  `app/temporal/activities/enhance_issue_activity.rb#delimited_payload`,
  `app/temporal/workflows/agent_execution_workflow.rb`,
  `app/controllers/api/github_proxy_controller.rb`,
  `app/services/containers/provision.rb#workspace_mount_mode`,
  `app/services/orchestration_strategies/defaults.rb#non_container_goals`.

## Runtime contract and bounded execution

- [x] **ISSUE-ENHANCEMENT-010** — When a deployment migrates an existing
  database whose active global `goal.enhance_issue` prompt does not match the
  source-controlled structured-output contract, the system SHALL create and
  promote the expected immutable prompt version under system tenant access.
  When the expected version is already active, migration SHALL make no prompt
  change.
  *Tests:* migration spec for the enhancement prompt synchronization.
  *Code:* enhancement prompt synchronization migration.

- [x] **ISSUE-ENHANCEMENT-011** — When Paid queues a new automatic
  `enhance_issue` run, the system SHALL atomically consume one enhancement
  round regardless of whether the run originated from initial analysis or
  human-answer re-evaluation. Duplicate queue requests and manual enhancement
  runs SHALL NOT consume a round. When the configured round limit has already
  been reached, Paid SHALL NOT create another enhancement run; it SHALL leave
  the issue in `manual_review` and post at most one marked
  auto-enhancement-stop comment. Automatic picking SHALL exclude
  `manual_review`; only an explicit operator-triggered run SHALL resume work,
  and queueing such a run SHALL move the issue out of `manual_review` in the
  same request (the queue-time state flip — see `OPERATOR-INBOX-002D`), with
  re-entry only through the enhancement stop paths. Entering
  `manual_review` SHALL clear stored clarification questions and remove
  the enhancement needs-input label so GitHub and Paid do not show contradictory
  lifecycle states. Only a marker comment authored by Paid's GitHub App SHALL
  suppress the stop notice; the marker text is unauthenticated, so trusting
  allowlisted human collaborators would let any one of them forge the marker
  and silence platform feedback, breaking the convention used by other
  marker-based status comments.
  *Tests:* `spec/temporal/activities/queue_agent_run_activity_spec.rb`,
  `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `app/temporal/activities/queue_agent_run_activity.rb`,
  `app/temporal/activities/fetch_issues_activity.rb`.

## Manual-review visibility

- [x] **ISSUE-ENHANCEMENT-012** — When an issue's `paid_state` transitions
  into `manual_review`, the system SHALL stamp a durable
  `manual_review_started_at` timestamp (preserved across idempotent
  re-application of the same state, mirroring `needs_input_since`) and SHALL
  persist a human-readable `manual_review_reason` describing why automation
  stopped, sourced from `IssueEnhancements::StopForManualReview`'s `reason`
  wherever the issue enters `manual_review` through that service, and from the
  equivalent round-limit copy where `EnhanceIssueActivity` sets the state
  directly. When `paid_state` leaves `manual_review`, the system SHALL clear
  both columns. The operator inbox (`docs/intent/operator-inbox/`) SHALL
  derive an issue's manual-review age from `manual_review_started_at` (falling
  back to `updated_at` for legacy rows predating the column) rather than
  `updated_at`, the same fallback precedent `pr_escalation_started_at`
  established on the PR side.
  *Tests:* `spec/models/issue_spec.rb`,
  `spec/services/issue_enhancements/stop_for_manual_review_spec.rb`,
  `spec/temporal/activities/enhance_issue_activity_spec.rb`.
  *Code:* `app/models/issue.rb#sync_manual_review_started_at`,
  `app/services/issue_enhancements/stop_for_manual_review.rb`,
  `app/temporal/activities/enhance_issue_activity.rb`.

- [x] **ISSUE-ENHANCEMENT-013** — When project-level issue enhancement is off,
  a trusted issue-scoped activation label (`paid-enhance` or `paid-in-full`)
  SHALL switch that issue's auto-pick path from `create_pr` to
  `analyze_issue`, while unlabeled issues continue to bypass enhancement.
  *Tests:* `spec/services/automation/strategies/auto_pick_spec.rb`,
  `spec/services/issues/enqueue_eligible_spec.rb`.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`,
  `app/services/automation/strategies/auto_pick.rb`.

- [x] **ISSUE-ENHANCEMENT-014** — When enhancement concludes `sufficient_context:
  true`, the system SHALL queue a `create_pr` follow-up run via
  `CreateFollowupRunActivity` (mirroring the analyze branch) so the
  analyze→enhance loop converges to `create_pr` instead of parking the
  issue in the non-eligible `completed` paid_state forever (#3842).
  Insufficient verdicts SHALL NOT queue a follow-up — the issue is parked
  awaiting human input. The system SHALL reset `enhance_issue_rounds` on
  the successful verdict (the lane has converged; a later regression must
  not inherit an exhausted automatic-retry budget that would deadlock the
  next cycle) and SHALL also reset it on the meaningful human signal of
  clearing the `needs_input` label (either via `ClearNeedsInput` when a
  human answer comment arrives or via `FetchIssuesActivity` when the label
  is removed on GitHub). The reset on human signal only clears the
  automatic cap; manual runs never consume a round at queue time so they
  have nothing to reset.
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`
  ("queues a create_pr follow-up when enhancement concludes sufficient_context: true", "does not queue a create_pr follow-up when enhancement concludes insufficient"),
  `spec/temporal/activities/enhance_issue_activity_spec.rb`
  ("resets the enhancement round counter when sufficient_context is true", "does not reset the enhancement round counter when sufficient_context is false"),
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`
  ("resets the enhancement round counter alongside paid_state").
  *Code:* `app/temporal/workflows/agent_execution_workflow.rb`,
  `app/temporal/activities/enhance_issue_activity.rb#reset_enhancement_rounds!`,
  `app/services/clarifying_questions/clear_needs_input.rb`,
  `app/temporal/activities/fetch_issues_activity.rb#detect_needs_input_label_removals`.

- [x] **ISSUE-ENHANCEMENT-015** — The `create_pr` follow-up queued by
  ISSUE-ENHANCEMENT-014 is a single fire-and-forget activity call: if the
  workflow dies between `EnhanceIssueActivity` completing and
  `CreateFollowupRunActivity` running, the issue is stranded in the
  non-eligible `completed` paid_state with nothing to reconcile it (#3851).
  `EnhanceIssueActivity` SHALL stamp `last_analyzer_sufficient_context` with
  every readiness verdict (mirroring `AnalyzeIssueActivity`), unifying the
  "last verdict" signal across both goals. Auto-Pick candidate selection
  SHALL treat a `completed` issue with `last_analyzer_sufficient_context:
  true` as recoverable, independent of whether the run that produced the
  verdict was itself an automatic auto-pick run — so a manually triggered or
  sync-queued `enhance_issue` run is reconciled the same as one chained from
  `analyze_issue`. When such an issue is re-picked, the seeded goal SHALL be
  `create_pr` directly rather than restarting the analyze/enhance loop.
  Issues completed for unrelated reasons (`no_code_required_at`, a merged
  linked PR) remain excluded by their own permanent guards, which apply
  before this recovery path is considered.
  *Tests:* `spec/temporal/activities/enhance_issue_activity_spec.rb`
  ("stamps last_analyzer_sufficient_context on the issue when sufficient_context is true",
  "stamps last_analyzer_sufficient_context false on the issue when sufficient_context is false"),
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`
  ("recovers a completed issue with a prior sufficient-context verdict when no follow-up run was ever queued",
  "does not recover a completed issue whose sufficient-context follow-up run is already in flight",
  "does not recover a completed issue whose verdict was insufficient context"),
  `spec/models/issue_spec.rb`
  ("returns :eligible for a completed issue with a prior sufficient-context verdict and no in-flight run"),
  `spec/services/issues/enqueue_eligible_spec.rb`
  ("seeds create_pr directly for a completed issue with a prior sufficient-context verdict, even with auto_enhance enabled").
  *Code:* `app/temporal/activities/enhance_issue_activity.rb#complete_run!`,
  `app/models/issue.rb#auto_pick_eligible_paid_state_scope`,
  `app/services/issues/enqueue_eligible.rb#seeded_goal`.

- [x] **ISSUE-ENHANCEMENT-016** — The `enhance_issue_rounds` cap SHALL also
  reset on a trusted collaborator's edit to the issue body, not only on the
  `needs_input` human-signal paths in `ISSUE-ENHANCEMENT-014` (#3849): when
  `FetchIssuesActivity` syncs an issue whose author is currently trusted
  (`Project#trusted_github_author?`) and the synced body differs from the
  locally stored body, and the counter is non-zero, the system SHALL reset
  `enhance_issue_rounds` to 0. This is a best-effort proxy — GitHub's issue
  representation does not report who last edited the body, only who created
  the issue — so the reset SHALL NOT fire for an issue whose current author
  is untrusted, and SHALL NOT fire on the initial sync that creates the
  issue (there is no "prior" body to diverge from). The body change SHALL
  be detected by comparing the synced body against the locally stored body
  from before the upsert — not via the record's last-save change tracking,
  which `Issues::UpsertFromGithub` can replace with a later save on the
  same instance (a recommend-close label removal) and silently mask the
  edit. The reset SHALL be
  reflected in the sync's `changed` result even when the body was the only
  change.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`
  ("resets enhance_issue_rounds to 0", "does not reset the round counter when the body is unchanged", "does not reset the round counter when the issue's author is untrusted", "still resets the round counter when a recommend-close label removal lands in the same sync").
  *Code:* `app/temporal/activities/fetch_issues_activity.rb#sync_issue`,
  `#reset_enhancement_rounds_on_trusted_body_edit!`.

- [x] **ISSUE-ENHANCEMENT-017** — When an issue body looks truncated or
  corrupted (`Issues::DetectTruncatedBody`), both the enhance agent's prompt
  (`RunAgentActivity#augment_prompt_for_enhance_issue_goal`) and the posted
  enhancement comment SHALL name the condition explicitly — the agent is
  told not to guess at the missing intent or treat the fragment as the whole
  spec, and the comment carries a visible notice that the original intent
  may be lost — instead of silently guessing at intent from a partial draft
  (#3852). Well-formed bodies SHALL see no prompt or comment change.
  *Tests:* `spec/services/issues/detect_truncated_body_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`
  ("when the issue body appears truncated or corrupted", "when the issue body is well-formed"),
  `spec/temporal/activities/enhance_issue_activity_spec.rb`
  ("when the issue body appears truncated or corrupted", "when the issue body is well-formed").
  *Code:* `app/services/issues/detect_truncated_body.rb`,
  `app/temporal/activities/run_agent_activity.rb#inject_body_integrity_note`,
  `app/temporal/activities/enhance_issue_activity.rb#comment_body_for`.
