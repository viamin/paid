# EARS Specs: Eager Queue Seeding

> Testable claims for eagerly seeding eligible issues into the auto-pick
> queue and rechecking that eligibility at dequeue time (RDR-032). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r EAGER-QUEUE-001`).

## Single-issue seeding

- [x] **EAGER-QUEUE-001** — When an eligible issue is enqueued for an
  auto-pick-enabled project, the system SHALL create one queued automatic
  `AgentRun` (with a resolved agent type) via `find_or_create_by!` against
  the unique-active-run index, so concurrent enqueue attempts resolve to the
  same run rather than producing duplicates.
  *Code:* `Issues::EnqueueEligible#call`, `Issues::EnqueueEligible#blocking_runs`.
  *Test:* `spec/services/issues/enqueue_eligible_spec.rb`.

- [x] **EAGER-QUEUE-002** — When Auto-Pick is disabled for a project, the
  enqueue path SHALL create no new run, so stale sync or retry work cannot
  recreate queued Auto-Pick runs after the operator turns the feature off.
  *Code:* `Issues::EnqueueEligible#call` (auto_pick_enabled guard).
  *Test:* `spec/services/issues/enqueue_eligible_spec.rb`,
  `spec/models/project_spec.rb`.

## Bulk seeding

- [x] **EAGER-QUEUE-003** — When all currently-eligible issues for a project
  are seeded at once, the system SHALL iterate the eligible scope in batches
  and delegate to the single-issue path per issue (no bulk upsert), counting
  created, existing, and skipped runs for observability.
  *Code:* `Issues::BulkEnqueueEligible#call`,
  `Issues::BulkEnqueueEligible#each_eligible_issue`.
  *Test:* `spec/services/issues/bulk_enqueue_eligible_spec.rb`.

## Reactive seeding triggers

- [x] **EAGER-QUEUE-004** — The system SHALL seed eligible issues on issue
  lifecycle events rather than only on a scheduler tick: per-issue on an
  incremental GitHub sync, in bulk on a full sync or project import, in
  bulk when `auto_pick_enabled` is toggled on, and per-dependent when a
  blocking issue closes.
  *Code:* `FetchIssuesActivity#seed_eligible_issues`,
  `Project#seed_eligible_issues`, `Issue#enqueue_newly_unblocked_dependents`,
  `AutoPickQueueBackfillJob`, `AutoPickEligibilitySweepJob`.
  *Test:* `spec/temporal/activities/fetch_issues_activity_spec.rb`,
  `spec/models/project_spec.rb`, `spec/models/issue_spec.rb`.

## Dequeue-time eligibility recheck

- [x] **EAGER-QUEUE-005** — When the scheduler is about to claim a queued
  auto-pick run tied to an issue, the system SHALL re-check that issue's
  eligibility at dequeue time, and SHALL cancel the run (freeing its slot
  and removing it from the dashboard preview) when the issue is no longer
  eligible — skip label, new blocking dependency, closed issue, or paused —
  so the re-enqueue hooks can recreate it if the issue becomes eligible
  again. An open issue's internal `paid_state` SHALL NOT by itself cancel
  the run.
  *Code:* `AgentRuns::RecheckIssueEligibility#call`,
  `AgentRuns::RecheckIssueEligibility#cancel_run`,
  `ProcessRunQueueJob` recheck invocation.
  *Test:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`.

- [x] **EAGER-QUEUE-006** — The dequeue recheck SHALL apply only to
  eagerly-seeded auto-pick runs tied to an issue, and SHALL skip manual
  runs, runs with no issue, and `review` goals.
  *Code:* `AgentRuns::RecheckIssueEligibility#recheck_applicable?`.
  *Test:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`.

## Failed-run re-enqueue backoff

- [x] **EAGER-QUEUE-007** — When a failed run makes an issue re-enter the
  queue, the system SHALL delay re-enqueue by Sidekiq's exponential curve
  `(n**4) + 15 + jitter` seconds (n = consecutive auto-pick failure count
  minus one), bounded so the count saturates at 50, so first retries are
  fast and persistently broken issues taper out rather than cycling forever.
  Re-enqueues following a non-`failed` state transition SHALL be immediate.
  *Code:* `Issue#auto_pick_reenqueue_delay`,
  `Issue#consecutive_auto_pick_failure_count`,
  `Issue#enqueue_self_if_became_auto_pick_eligible`,
  `Issues::ReenqueueEligibleJob`.
  *Test:* `spec/models/issue_spec.rb`.

## Duplicate-PR prevention

- [x] **EAGER-QUEUE-009** — When a project issue has a `create_pr` run that
  recorded a `pull_request_number`, the system SHALL exclude that issue from
  queue seeding and dequeue eligibility while a synced PR in the same project
  with that number and canonical GitHub URL is open or merged, regardless of
  elapsed time, a missing
  `parent_issue_id`, or the run's terminal status — a run that fails or is
  cancelled after publishing still counts, because the recorded number, not
  the terminal status, is the produced-PR evidence. The exclusion SHALL lift
  immediately when the synced PR is authoritatively closed unmerged. A
  missing PR row is protected for `PR_SYNC_GRACE_PERIOD` (armed by the
  `completed_at` every terminal transition stamps) and then triggers
  reconciliation rather than being treated as proof that a second PR may be
  created. Runs without a source issue SHALL NOT exclude unrelated issues
  from queue seeding or dequeue eligibility, even when their recorded PR is
  open or merged.
  *Code:* `Automation::Strategies::AutoPick::DefaultCandidateSource`,
  `Issue.open_paid_generated_pull_request_source_issue_ids`,
  `Issues::ReconcilePullRequestSource`.
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/services/issues/reconcile_pull_request_source_spec.rb`.

- [x] **EAGER-QUEUE-010** — Before an issue implementation run publishes a
  PR, the system SHALL serialize on the source issue and reject a new PR when
  an open implementation PR already exists for that source, even if the new
  run uses a different branch. After creating a PR, the originating run SHALL
  durably reserve its URL and number before releasing the source-issue lock,
  so concurrent branches can reconcile and discover it before terminal
  completion. Rejected work SHALL not be marked delivered by returning the
  existing PR URL. Reconciliation SHALL link a PR to a source only when all
  matching originating runs agree, and SHALL preserve a PR-follow-up run's
  original source relationship.
  *Code:* `Activities::CreatePullRequestActivity`,
  `Issues::ReconcilePullRequestSource`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`,
  `spec/services/issues/reconcile_pull_request_source_spec.rb`.

- [x] **EAGER-QUEUE-011** — For a synthetic code-scanning issue specifically,
  a merged remediation PR SHALL exclude the issue from queue seeding and
  dequeue eligibility only until `SecurityAlerts::ProcessCodeScanningAlerts`
  next reconciles that alert — a merge alone SHALL NOT be treated as proof
  the alert is fixed. Every reconciliation pass over an alert still reported
  as open SHALL stamp `last_scanner_reconciled_at`, whether or not the
  issue's title/body/labels changed. Once that timestamp is at or after the
  most recent merged remediation PR's observed time, the exclusion SHALL
  lift so a still-open (recurrent) alert can be re-picked. An ordinary
  GitHub issue's merged-PR exclusion SHALL remain permanent, unaffected by
  this carve-out.
  *Code:* `Automation::Strategies::AutoPick::DefaultCandidateSource#merged_block_issue_ids`,
  `SecurityAlerts::ProcessCodeScanningAlerts`.
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/services/security_alerts/process_code_scanning_alerts_spec.rb`.

- [x] **EAGER-QUEUE-013** — After a remediation PR for a synthetic code-scanning
  issue merges, Paid SHALL retain a distinct remediation-attempt record and
  suppress automatic remediation while verification is awaiting, blocked, or
  has found the same finding still open. Verification SHALL use a successful
  analysis on the target branch with the finding's tool/category and a commit
  containing the merge commit; it SHALL record the analysis and PR evidence.
  A matching analysis with the finding still open SHALL put the issue into
  manual review, not create another automatic fix run. Missing, failed,
  wrong-branch/configuration, or pre-merge analysis SHALL be blocked, never
  treated as resolution. Alert timestamps are not scan-freshness evidence.
  *Code:* `CodeScanningRemediationAttempt`,
  `SecurityAlerts::VerifyRemediationAttempt`,
  `Automation::Strategies::AutoPick::DefaultCandidateSource`.
  *Test:* `spec/services/security_alerts/verify_remediation_attempt_spec.rb`.

- [x] **EAGER-QUEUE-014** — When `SecurityAlerts::VerifyMergedRemediationAttempts`
  runs against a synthetic code-scanning issue whose latest attempt is
  `verification_blocked`, the verifier SHALL re-evaluate it against the freshly
  fetched analyses and SHALL treat the re-evaluation under the same evidence
  rules EAGER-QUEUE-013 requires for first-time verification: a matching
  post-merge analysis on the target branch that contains the merge commit.
  Each blocked attempt SHALL be revisited on every relevant scan or
  credential repair (worker restart, repeated polls, manual retry) without
  deleting or rewriting prior attempt history. A still-blocked attempt SHALL
  keep its previous status and append the latest evidence; a previously
  blocked attempt that now meets the rules SHALL transition to `verified_fixed`
  (alert closed) or `verification_failed` (alert still open), and only the
  latter SHALL move the source issue into `manual_review`. A blocked attempt
  whose source issue was closed on GitHub or whose underlying PR has been
  unmerged SHALL be left as historical, not relaunched into a new fix run.
  *Code:* `SecurityAlerts::VerifyMergedRemediationAttempts`,
  `SecurityAlerts::VerifyRemediationAttempt`,
  `CodeScanningRemediationAttempt.retryable_block`,
  `CodeScanningRemediationAttempt.latest_per_issue`.
  *Test:* `spec/services/security_alerts/verify_merged_remediation_attempts_spec.rb`,
  `spec/models/code_scanning_remediation_attempt_spec.rb`.

- [x] **EAGER-QUEUE-015** — The auto-pick exclusion derived from a
  `code_scanning_remediation_attempts` row SHALL be governed by the latest
  attempt per issue, not by any earlier superseded attempt. A new merged
  remediation PR SHALL be permitted to record a fresh attempt whose status
  alone determines whether the issue is excluded; a prior
  `verification_failed` or `verification_blocked` row SHALL NOT keep the
  issue out of auto-pick once superseded. The duplicate-PR prevention
  guards (EAGER-QUEUE-009) remain authoritative — a freshly merged PR still
  excludes the issue until scanner reconciliation and verification clear it.
  *Code:* `Automation::Strategies::AutoPick::DefaultCandidateSource#code_scanning_verification_block_issue_ids`,
  `CodeScanningRemediationAttempt.latest_per_issue`.
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.

- [x] **EAGER-QUEUE-016** — When a project's latest attempt against a synthetic
  code-scanning issue is `verification_blocked` and the issue is not already
  in the manual_review lane (i.e. retryable evidence has not yet escalated),
  the system SHALL publish a blocking `code_scanning_verification_blocked`
  notification carrying the alert URL, linked PRs, blocked reason, the
  attempt's age, the project's last successful scan timestamp, and a next
  action. The notification SHALL be re-issued (idempotent on
  `(source, subject)`) on every relevant scan so repeated polls and worker
  restarts keep the surfaced state current, and SHALL be auto-resolved when
  the attempt transitions to `verified_fixed` or `verification_failed` (the
  latter moves the issue into the existing manual_review lane and provides
  the operator escalation). Persistent configuration failures (missing
  trusted GitHub usernames) and token permission errors (missing
  `code_scanning_alerts:read` scope) SHALL each publish a distinct blocking
  notification scoped to the project so the operator can resolve them; both
  SHALL be auto-resolved on the next successful scan.
  *Code:* `Notifications::Rules::CodeScanningVerificationBlocked`,
  `Notifications::Rules::CodeScanningConfigurationError`,
  `Notifications::Rules::CodeScanningPermissionsError`,
  `SecurityAlerts::ScanSecurityAlertsActivity`,
  `Activities::EvaluateNotificationRulesActivity`.
  *Test:* `spec/services/notifications/rules/code_scanning_verification_blocked_spec.rb`,
  `spec/services/notifications/rules/code_scanning_configuration_error_spec.rb`,
  `spec/services/notifications/rules/code_scanning_permissions_error_spec.rb`.

- [x] **EAGER-QUEUE-012** — An operator-invoked repair path SHALL exist to
  backfill a missing `parent_issue_id` link between an existing PR and its
  originating `create_pr` run, using the same run-evidence matching as
  `Issues::ReconcilePullRequestSource` (idempotent; a PR history with more
  than one distinct candidate source issue SHALL be reported, not guessed
  or auto-linked). After repairing links, any queued run the repair proves
  is now a duplicate SHALL be cancelled through the normal dequeue
  eligibility/cancellation path (`AgentRuns::RecheckIssueEligibility`)
  rather than left runnable.
  *Code:* `Issues::ReconcilePullRequestSource.candidate_source_issues`,
  `lib/tasks/issues.rake` (`issues:repair_pull_request_source_links`).
  *Test:* `spec/tasks/issues_rake_spec.rb`.

## Capacity remains the single gate

- [x] **EAGER-QUEUE-008** — Eager seeding SHALL NOT itself limit concurrency
  or PR attention; `max_concurrent_runs` (with tenant guardrail) SHALL be
  the single capacity gate, and `AgentRun::QUEUE_ORDER` with its project/user
  fair-stride keys SHALL decide dispatch order unchanged by queue depth.
  *Code:* `ProcessRunQueueJob`, `AgentRun::QUEUE_ORDER`,
  `Capacity::RunAdmission`.
  *Test:* `spec/jobs/process_run_queue_job_spec.rb`.
