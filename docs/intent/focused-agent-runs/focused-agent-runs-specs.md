# EARS Specs: Focused Agent Runs

> Testable claims for single-problem-per-run scoping of PR follow-up work
> (RDR-031). Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r FOCUSED-RUN-001`).

## Focus field and validation

- [x] **FOCUSED-RUN-001** — The system SHALL persist a non-null `focus`
  column on `agent_runs` defaulting to `"general"`, validated against the
  fixed set `general, ci_fix, review_feedback, merge_conflict, conversation,
  performance_regression, issue_implementation, label_action`, so every run resolves to a defined
  focus and legacy/all-in-one runs behave exactly as before.
  *Code:* `AgentRun::FOCUSES`, `AgentRun` focus validation, `AgentRun#focused?`.
  *Test:* `spec/models/agent_run_spec.rb`.

## Scanner focus resolution

- [x] **FOCUSED-RUN-002** — When the PR scanner collects triggers for a run,
  the system SHALL resolve a single focus by mapping each trigger type to a
  focus (`TRIGGER_TO_FOCUS`) and selecting the highest-priority focus
  present per `FOCUS_PRIORITY` (`merge_conflict > ci_fix > review_feedback >
  conversation > issue_implementation > label_action`), falling back to
  `general` when no mapped trigger is present.
  *Code:* `ScanPaidPrsActivity#resolve_focus`, `ScanPaidPrsActivity#focus_for`,
  `ScanPaidPrsActivity::FOCUS_PRIORITY`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_focus_resolution_spec.rb`.

## Focused prompt scoping

- [x] **FOCUSED-RUN-003** — When a run is focused (non-`general`), the PR
  prompt builder SHALL include only the section for that focus, collapse the
  priority list to the single scoped task, and append an "Other Issues
  (Deferred)" section instructing the agent to ignore fix-forward for the
  other present problem classes; `general` and `label_action` runs SHALL
  include all applicable sections unchanged.
  A `performance_regression` run's section SHALL be built from the regression
  evidence persisted on the run (route, comparison metric, baseline and current
  values, sample spread) rather than from live measurement.
  *Code:* `Prompts::BuildForPr#focused?`, `#include_section?`,
  `#scoped_section_for_focus`, `#focused_priority_list`,
  `#other_issues_section`, `#deferred_issue_descriptions`.
  *Test:* `spec/services/prompts/build_for_pr_spec.rb`.

## Focus-scoped quality scoring

- [x] **FOCUSED-RUN-004** — When computing a run's composite quality score,
  the system SHALL select weights from `QualityMetric::FOCUS_WEIGHTS` by the
  run's focus for non-`general` focuses, and SHALL fall back to the general
  composite weights for `general`, so a focused run is judged against the
  metric for its actual task.
  *Code:* `QualityMetric::FOCUS_WEIGHTS`, `QualityMetric.weights_for`.
  *Test:* `spec/models/quality_metric_spec.rb`,
  `spec/services/quality_metrics/calculate_composite_score_spec.rb`.

## focus_resolved attribution

- [x] **FOCUSED-RUN-005** — On the scan cycle after a focused run completes,
  the system SHALL write a `focus_resolved` score (1.0 resolved / 0.0 not)
  back to that run's automated `QualityMetric` by re-checking the current PR
  state for its focus — for a `performance_regression` run, whether the page
  load finding it was queued for has resolved — deferring (no write) while CI
  checks for a `ci_fix` run are still pending, and SHALL recompute the composite score with the
  focus-specific weights once the value lands.
  *Code:* `ScanPaidPrsActivity#record_focus_resolution`,
  `#focus_resolution_scores`, `#focus_resolution_pending?`,
  `ScanPaidPrsActivity::FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_focus_resolution_spec.rb`.

## Conversation feedback consumption

- [x] **FOCUSED-RUN-010** — When a `create_pr` run on an existing PR
  completes or terminates `no_output` with the `no_changes` reason, the PR
  scanner SHALL use the newest successful prompt-preparation start across
  eligible terminal runs as the conversation-comment cutoff, so comments
  arriving after preparation remain actionable even when they precede run
  completion. Only legacy runs without any recorded prompt preparation may
  use `completed_at`; failed or post-completion preparation SHALL NOT
  acknowledge feedback. Eligibility requires a focus that includes the conversation section (the
  `conversation` focus, plus the unscoped `general` and `label_action`
  focuses that include every applicable section). A completed or no-change
  run with any other focus, failed or unfinished runs, and runs from other PRs
  or other projects SHALL NOT consume comments. Comments newer than an
  applicable cutoff SHALL remain actionable; review-thread,
  changes-requested, review-bot, CI, policy, and budget gating SHALL keep
  deriving their cutoffs from completed runs only.
  *Code:* `ScanPaidPrsActivity#check_conversation_comments`,
  `ScanPaidPrsActivity#conversation_feedback_cutoff`,
  `ScanPaidPrsActivity#conversation_scope_runs`,
  `ScanPaidPrsActivity#conversation_context_cutoff_sql`,
  `ScanPaidPrsActivity::CONVERSATION_SCOPE_FOCUSES`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_conversation_feedback_spec.rb`.

## Follow-up loop breaker

- [x] **FOCUSED-RUN-006** — When PR scan lifecycle signals show a
  create-pr follow-up loop is stuck with no meaningful progress, the
  auto-continue strategy SHALL escalate instead of queueing another
  create-pr follow-up for the same unresolved review/CI/comment trigger,
  unless the ready-phase limits are temporarily suspended under
  `PR-ESCALATION-028`;
  pending review-run triggers SHALL still be allowed to proceed. Draft and
  restarted PRs SHALL also treat `max_draft_review_rounds` as a hard attempt
  cap: once `draft_review_count` reaches that configured limit, the scanner
  SHALL escalate instead of queueing another draft follow-up even if recent
  commits would otherwise reset the no-progress heuristic.
  *Code:* `Automation::Strategies::AutoContinue#escalation_candidate?`,
  `ScanPaidPrsActivity#draft_review_limit_reached?`.
  *Test:* `spec/services/automation/strategies/auto_continue_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **FOCUSED-RUN-007** — When automatic PR automation for one pull request
  has already consumed at least the project's `max_pr_auto_continue_tokens`
  and the project has no active suspension under `PR-ESCALATION-028`,
  the poll workflow SHALL skip queueing another automatic create-pr or review
  run for that PR and SHALL escalate the PR to the owner instead, even when an
  existing queued automatic PR run is still active. A bounded allowance granted
  by an owner dismissal is included in the effective limit; a timestamp-only
  legacy override is not. Clearing the resulting escalation is owned by
  `PR-ESCALATION-006` and the bounded override semantics by
  `PR-ESCALATION-007`.
  *Code:* `CheckQualityGateActivity#pr_auto_continue_token_limit_result`,
  `GitHubPollWorkflow#handle_quality_gate_block`,
  `ScanPaidPrsActivity#pr_auto_continue_token_limit_breach`,
  `Automation::Strategies::AutoContinue#evaluate`.
  *Test:* `spec/temporal/activities/check_quality_gate_activity_spec.rb`,
  `spec/temporal/workflows/git_hub_poll_workflow_spec.rb`,
  `spec/services/automation/strategies/auto_continue_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **FOCUSED-RUN-009** — When a project enables Paid Agent review, the
  system SHALL add `paid-code-reviewer[bot]` to that project's trusted GitHub
  username allowlist; when that enabled reviewer leaves unresolved PR review
  threads, the PR follow-up prompt SHALL include those review comments and
  SHALL return their thread IDs for the current follow-up's evidence. The PR review-thread path SHALL also
  accept GitHub's bare `paid-code-reviewer` app-author form only for configured
  review-thread feedback, without adding that bare login to the global comment
  allowlist.
  *Code:* `Project#ensure_paid_reviewer_bot_allowlisted`,
  `Prompts::BuildForPr#trusted_review_threads`,
  `Prompts::BuildForPr#unresolved_review_thread_ids`,
  `AgentExecutionWorkflow`.
  *Test:* `spec/models/project_spec.rb`,
  `spec/services/prompts/build_for_pr_spec.rb`.

- [x] **FOCUSED-RUN-013** — When the latest review from an allowlisted human
  or configured review bot is a nonblank `COMMENTED` standalone review body
  submitted after the completed-run cutoff, the PR scanner SHALL emit the
  existing `review_feedback` follow-up route even with no unresolved inline
  threads. A configured Paid Agent review whose body records its machine-readable
  clean verdict or configured review-bot summary matching the shared
  clean-review classifier SHALL NOT route a follow-up despite its nonblank
  `COMMENTED` state. An excluded author, an empty state, a superseded finding, or a review
  at or before that cutoff SHALL NOT route a follow-up. A configured bot's
  `COMMENTED` review with associated inline comments SHALL retain the existing
  thread lifecycle rather than emit standalone feedback. Unavailable inline
  comment state SHALL remain an incomplete review gate; only a known absence
  of associated comments SHALL admit that bot body as standalone. Existing review, merge,
  retry, and allowance decisions remain unchanged.
  *Code:* `ScanPaidPrsActivity#standalone_review_feedback_from_reviews`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **FOCUSED-RUN-011** — When an existing pull-request follow-up pushes a
  changed or rebase-only head, or reports no changes, Paid SHALL NOT resolve a
  captured review thread merely because the run completed, pushed, or reports
  that the feedback was already addressed. A thread remains actionable until a
  current-head, explicitly authorized, exact-thread-version-bound assessment supplies explicit
  supported rationale from evidence that includes the thread's original
  finding. Complete thread evidence SHALL be fetched within finite page,
  request, and evidence-size budgets, rejecting missing, repeated, or cyclic
  pagination cursors. Failed, unavailable, incomplete, malformed, stale,
  concurrently changed, over-budget, or no-op assessment cannot resolve it.
  Immutable comparison file lists SHALL be complete within their configured
  limit; a local cutoff or an unprovable upstream file-list limit SHALL refuse
  assessment. Required per-file path, status, blob identity, change counts and
  rename provenance SHALL be structurally valid before model authorization;
  status SHALL be a declared GitHub diff-entry status. Binary metadata does
  not require a textual patch. The bounded model evidence SHALL retain every
  compared file, sharing its patch budget through explicit excerpts. If all
  file metadata and bounded per-file evidence cannot fit, assessment SHALL
  remain unavailable before a model request. A thread omitted from the
  bounded prompt SHALL NOT be authorized.
  This does not prohibit a supported no-code disposition such as invalid,
  outdated, or already-fixed feedback.
  *Code:* `AgentExecutionWorkflow#execute`,
  `AssessFollowupReviewThreadsActivity`, `ResolveReviewThreadsActivity`,
  `GithubClient#detailed_compare_files`.
  *Test:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/services/github_client_spec.rb`,
  `spec/temporal/activities/assess_followup_review_threads_activity_spec.rb`,
  `spec/temporal/activities/resolve_review_threads_activity_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`.

- [x] **FOCUSED-RUN-012** — When the latest review from a body-only-capable
  reviewer has inline comments but no unresolved review threads, Paid SHALL NOT
  admit another coding follow-up for those resolved comments, even when the
  review post-dates the last completed run. Paid SHALL keep a
  genuine top-level-only finding actionable, fail closed when review-comment
  data is unavailable, and SHALL NOT infer resolution from a changed related or
  unrelated file.
  *Code:* `ScanPaidPrsActivity#check_review_bot_status`,
  `Automation::Signals::PullRequestCollector#review_inline_comment_state`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
