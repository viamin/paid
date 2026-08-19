# EARS Specs: PR Escalation Recovery

> Testable claims for how a stopped pull request is held, surfaced, and
> cleared. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r PR-ESCALATION-001`).

## The escalated phase is the hold

- [x] **PR-ESCALATION-001** — While a pull request's review phase is
  `escalated`, the PR scan SHALL detect only recovery conditions (escalation
  cleared, owner approval that unblocks auto-merge) and SHALL NOT collect CI,
  review-thread, merge-conflict, or conversation triggers, nor queue any
  follow-up run for that pull request, including on the skip-unchanged
  merge-conflict rescan path.
  *Code:* `ScanPaidPrsActivity#scan_escalated_pr`,
  `ScanPaidPrsActivity#merge_conflict_rescan_needed?`,
  `Automation::Strategies::AutoContinue#evaluate`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **PR-ESCALATION-002** — The system SHALL represent the escalation hold
  solely as the `escalated` review phase, and SHALL NOT set the operator's
  per-PR auto-continue pause when escalating a pull request.
  *Code:* `MarkEscalatedActivity#execute`.
  *Test:* `spec/temporal/activities/mark_escalated_activity_spec.rb`.

- [x] **PR-ESCALATION-003** — The PR scan source SHALL exclude a pull request
  from scanning only while the operator's per-PR auto-continue pause is set, so
  that a pull request stopped by the system stays visible to the scan that
  detects its recovery.
  *Code:* `Issue.auto_continue_active`, `ScanPaidPrsActivity#find_paid_prs`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/models/issue_spec.rb`.

- [x] **PR-ESCALATION-004** — When a pull request is escalated, the system
  SHALL leave automatic runs already queued for that pull request in the queue.
  *Code:* `MarkEscalatedActivity#execute`.
  *Test:* `spec/temporal/activities/mark_escalated_activity_spec.rb`.

## Clearing an escalation

- [x] **PR-ESCALATION-005** — When an escalation is cleared by an owner-initiated
  path (the owner removing `paid-escalated`, the pull request being converted to
  draft while escalated, or an operator Unblock action), the system SHALL apply
  one clearing operation that clears the escalated phase and the escalation
  reason, removes `paid-escalated` from the pull request's labels, zeroes
  `draft_review_count`, `pr_followup_count`, `review_goal_retry_count`, and
  `stuck_confirmation_count`, stamps `review_goal_retry_reset_at` and
  `operational_failure_reset_at`, and clears `ci_retry_requested_at`.
  *Code:* `Issue#clear_escalation!`, `DismissEscalationActivity#execute`,
  `ScanPaidPrsActivity#maybe_restart_draft`.
  *Test:* `spec/models/issue_spec.rb`,
  `spec/temporal/activities/dismiss_escalation_activity_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **PR-ESCALATION-006** — When an escalation is cleared, the system SHALL
  set the pull request's review phase to `restarted` if the pull request is a
  draft and to `ready` otherwise.
  *Code:* `Issue#clear_escalation!`.
  *Test:* `spec/models/issue_spec.rb`.

- [x] **PR-ESCALATION-007** — When a `pr_auto_continue_token_limit` escalation
  is cleared, the system SHALL record a standing per-PR override of the
  project's automatic-run token cap and SHALL allow subsequent automatic runs
  on that pull request to exceed the cap.
  *Code:* `Issue#clear_escalation!`,
  `ScanPaidPrsActivity#pr_auto_continue_token_limit_breach`.
  *Test:* `spec/models/issue_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **PR-ESCALATION-008** — When an `operational_failures` escalation is
  dismissed automatically because its failure signals recovered, the system
  SHALL release the escalation without zeroing `draft_review_count`,
  `pr_followup_count`, `review_goal_retry_count`, or
  `stuck_confirmation_count`.
  *Code:* `ScanPaidPrsActivity#escalation_dismissed?`,
  `DismissEscalationActivity#execute`.
  *Test:* `spec/temporal/activities/dismiss_escalation_activity_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **PR-ESCALATION-009** — When a trusted GitHub user removes the
  `paid-escalated` label from an escalated pull request, the next scan of that
  pull request SHALL detect that removal from the pull request's label event
  history and clear the escalation as owner-initiated.
  *Code:* `ScanPaidPrsActivity#escalation_dismissed?`,
  `Automation::LabelPolicy.trusted_user_removed_label?`,
  `ScanPaidPrsActivity#dismiss_escalation_trigger`,
  `Automation::Strategies::AutoReview#evaluate`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/services/automation/label_policy_spec.rb`.

- [ ] **PR-ESCALATION-019** — If the `paid-escalated` label is absent from an
  escalated pull request without a recorded removal by a trusted GitHub user
  (for example the label write failed when the pull request was escalated, or
  the label event history cannot be fetched), then the system SHALL NOT treat
  the absence as an owner dismissal and SHALL leave the escalation in place.
  *Code:* `ScanPaidPrsActivity#escalation_dismissed?`,
  `Automation::LabelPolicy.trusted_user_removed_label?`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/services/automation/label_policy_spec.rb`.

- [ ] **PR-ESCALATION-021** — While a pull request's review phase is
  `escalated` and the `paid-escalated` label is absent without a removal by a
  trusted GitHub user, the scan SHALL re-apply the label to the pull request on
  GitHub, so the label always reflects the hold rather than drifting from it.
  *Code:* `ScanPaidPrsActivity#reapply_escalation_label_if_missing`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [ ] **PR-ESCALATION-020** — While a pull request is escalated, the scan
  staleness ceiling SHALL apply regardless of the pull request's author, so
  that a pull request whose GitHub `updated_at` has stopped advancing is still
  rescanned and its recovery can be detected.
  *Code:* `ScanPaidPrsActivity#scan_age_exceeds_ceiling?`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

## Blocked-work surface

- [x] **PR-ESCALATION-011** — The dashboard SHALL list every open pull request
  in the current account whose review phase is `escalated`, showing the
  escalation reason and how long the pull request has been stopped, ordered
  longest-stopped first.
  *Code:* `Dashboard::BlockedPullRequests`, `DashboardController#show`,
  `app/views/dashboard/_blocked_pull_requests.html.erb`.
  *Test:* `spec/services/dashboard/blocked_pull_requests_spec.rb`,
  `spec/requests/dashboard_spec.rb`.

- [x] **PR-ESCALATION-012** — For each listed pull request the dashboard SHALL
  show every counter that has reached its configured limit with that limit, and
  for an `operational_failures` escalation SHALL show the time since the pull
  request last made meaningful progress.
  *Code:* `Dashboard::BlockedPullRequests`.
  *Test:* `spec/services/dashboard/blocked_pull_requests_spec.rb`.

- [x] **PR-ESCALATION-013** — The blocked-PR listing SHALL exclude pull
  requests held only by the operator's per-PR auto-continue pause, and SHALL
  indicate that pause distinctly on any listed pull request that is both
  escalated and operator-paused.
  *Code:* `Dashboard::BlockedPullRequests`,
  `app/views/dashboard/_blocked_pull_requests.html.erb`.
  *Test:* `spec/services/dashboard/blocked_pull_requests_spec.rb`.

## Unblock action

- [x] **PR-ESCALATION-014** — When an authorized user unblocks a listed pull
  request, the system SHALL apply the escalation clearing operation under a row
  lock on the pull request and remove `paid-escalated` from the pull request on
  GitHub, and SHALL NOT enqueue an agent run. The unblock SHALL NOT release the
  operator's per-PR auto-continue pause on a pull request that also holds it.
  *Code:* `PullRequests::Unblock`,
  `Projects::AgentRunsController#unblock_escalation`.
  *Test:* `spec/services/pull_requests/unblock_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.

- [x] **PR-ESCALATION-015** — If an unblock is requested for a pull request
  that is no longer open, then the system SHALL refuse the unblock, leave the
  pull request's counters unchanged, and refresh the listing.
  *Code:* `PullRequests::Unblock`,
  `Projects::AgentRunsController#unblock_escalation`.
  *Test:* `spec/services/pull_requests/unblock_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.

- [x] **PR-ESCALATION-016** — If removing `paid-escalated` from GitHub fails
  during an unblock, then the system SHALL still apply the local escalation
  clearing and SHALL log the failure rather than aborting the unblock.
  *Code:* `PullRequests::Unblock`.
  *Test:* `spec/services/pull_requests/unblock_spec.rb`.

- [x] **PR-ESCALATION-017** — Unblocking a pull request SHALL be authorized by
  the same policy as running an agent on its project.
  *Code:* `Projects::AgentRunsController#unblock_escalation`, `ProjectPolicy`.
  *Test:* `spec/requests/agent_runs_spec.rb`,
  `spec/policies/project_policy_spec.rb`.

## Migration

- [x] **PR-ESCALATION-018** — The migration retiring the escalation-set pause
  SHALL release the operator's per-PR auto-continue pause on every open pull
  request whose review phase is `escalated`, and SHALL leave that pause
  unchanged on every other pull request.
  *Code:* `db/migrate/20260819042625_release_escalation_set_auto_continue_pause.rb`.
  *Test:* `spec/migrations/release_escalation_set_auto_continue_pause_spec.rb`.
