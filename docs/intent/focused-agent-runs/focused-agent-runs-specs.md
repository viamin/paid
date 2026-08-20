# EARS Specs: Focused Agent Runs

> Testable claims for single-problem-per-run scoping of PR follow-up work
> (RDR-031). Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r FOCUSED-RUN-001`).

## Focus field and validation

- [x] **FOCUSED-RUN-001** — The system SHALL persist a non-null `focus`
  column on `agent_runs` defaulting to `"general"`, validated against the
  fixed set `general, ci_fix, review_feedback, merge_conflict, conversation,
  issue_implementation, label_action`, so every run resolves to a defined
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
  state for its focus, deferring (no write) while CI checks for a `ci_fix`
  run are still pending, and SHALL recompute the composite score with the
  focus-specific weights once the value lands.
  *Code:* `ScanPaidPrsActivity#record_focus_resolution`,
  `#focus_resolution_scores`, `#focus_resolution_pending?`,
  `ScanPaidPrsActivity::FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_focus_resolution_spec.rb`.

## Follow-up loop breaker

- [x] **FOCUSED-RUN-006** — When PR scan lifecycle signals show a
  create-pr follow-up loop is stuck with no meaningful progress, the
  auto-continue strategy SHALL escalate instead of queueing another
  create-pr follow-up for the same unresolved review/CI/comment trigger;
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
  has already consumed at least the project's `max_pr_auto_continue_tokens`,
  the poll workflow SHALL skip queueing another automatic create-pr or review
  run for that PR and SHALL escalate the PR to the owner instead, even when an
  existing queued automatic PR run is still active. Clearing the resulting
  escalation is owned by `PR-ESCALATION-006`.
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
  SHALL return their thread IDs so the successful create-pr follow-up can
  resolve them after pushing changes. The PR review-thread path SHALL also
  accept GitHub's bare `paid-code-reviewer` app-author form only for configured
  review-thread feedback, without adding that bare login to the global comment
  allowlist.
  *Code:* `Project#ensure_paid_reviewer_bot_allowlisted`,
  `Prompts::BuildForPr#trusted_review_threads`,
  `Prompts::BuildForPr#unresolved_review_thread_ids`,
  `AgentExecutionWorkflow#resolve_followup_review_threads_after_push`.
  *Test:* `spec/models/project_spec.rb`,
  `spec/services/prompts/build_for_pr_spec.rb`.
