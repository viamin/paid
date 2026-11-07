# EARS Specs: Trusted Post-Deploy Measurement

> Testable claims for collecting trusted, read-only, allowlisted post-deploy
> measurements and feeding them into the existing partial-closeout
> prerequisite path. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target (`grep -r POST-DEPLOY-CHECK-001`).

- [x] **POST-DEPLOY-CHECK-001** — The system shall persist every post-deploy
  check attempt as a `PostDeployCheckRun` bound to account, project,
  check key, check version, deployed revision, idempotency key, status, and
  result, so a missing deployment signal, an execution failure, or a success
  all remain inspectable evidence rather than an unrecorded operator action.
  *Tests:* `spec/models/post_deploy_check_run_spec.rb`.
  *Code:* `PostDeployCheckRun`, `db/migrate/20261107075438_create_post_deploy_check_runs.rb`.

- [x] **POST-DEPLOY-CHECK-002** — When `PostDeployChecks::Run` is invoked
  with a `check_key` absent from `PostDeployChecks::Registry::ALLOWLIST`, the
  system shall raise `PostDeployChecks::UnknownCheckError` before persisting
  or executing anything, so only a reviewed, allowlisted check can ever run
  — never an operator-supplied query.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Registry`, `PostDeployChecks::Run#initialize`.

- [x] **POST-DEPLOY-CHECK-003** — Where a check's `source_issue` is not
  `deployed?`, or no `deployed_revision` is supplied, `PostDeployChecks::Run`
  shall record status `"unknown"` with a failure reason naming the missing
  signal and shall not execute the check, so an undeployed target never
  produces a fabricated result.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Run#deployment_blocked?`.

- [x] **POST-DEPLOY-CHECK-004** — When `PostDeployChecks::Run` is invoked
  twice with the same check key, project, and deployed revision, the system
  shall return the same `PostDeployCheckRun` row on the second call rather
  than re-executing the check once the first call reached `"succeeded"`, so
  duplicate deploy-pipeline events and retries are idempotent.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Run#find_or_initialize_run`, unique index
  `index_post_deploy_check_runs_idempotency`.

- [x] **POST-DEPLOY-CHECK-005** — When a check succeeds for a new deployed
  revision, the system shall mark every other current `PostDeployCheckRun`
  for the same check and project as superseded by the new row, so a reader
  scoped to `PostDeployCheckRun.current` never treats a stale revision's
  result as the current answer.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Run#supersede_prior_runs!`.

- [x] **POST-DEPLOY-CHECK-006** — The system shall scope every check's reads
  to the authorized project's own account and shall report the relevant
  total alongside the narrower measured count, so a zero result is
  interpretable rather than indistinguishable from "nothing in scope."
  *Tests:* `spec/services/post_deploy_checks/checks/closed_agent_planning_hold_reconciliation_count_spec.rb`.
  *Code:* `PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount`.

- [x] **POST-DEPLOY-CHECK-006B** *(tenant_isolation)* — When
  `PostDeployChecks::Run` executes with no tenant context established for
  the target project (no system-access bypass, no matching current
  account), the system shall raise `PostDeployChecks::AuthorizationError`
  before running the check, so an unestablished context is never
  indistinguishable from a passing zero-row read.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Run#require_authorized_context!`.

- [x] **POST-DEPLOY-CHECK-007** — When a succeeded check's result meets its
  target and a prerequisite notification/identity is supplied, the system
  shall write a `"sufficient"` evidence submission for that occurrence and
  shall resolve the notification with `released_by: "trusted_measurement"`
  only if every one of its current occurrences is already sufficient at its
  current source revision — never attesting the whole notification from one
  occurrence alone.
  *Tests:* `spec/services/post_deploy_checks/feed_prerequisite_evidence_spec.rb`.
  *Code:* `PostDeployChecks::FeedPrerequisiteEvidence`, `Notification#partial_closeout_prerequisite_released?`.

- [x] **POST-DEPLOY-CHECK-008** — When a succeeded check's result does not
  meet its target, or its occurrence's source revision is no longer current,
  the system shall record an `"insufficient"`/skipped evidence entry (or no
  entry, when the occurrence is stale) without resolving the notification,
  and re-feeding the same already-fed `PostDeployCheckRun` shall not append a
  duplicate submission.
  *Tests:* `spec/services/post_deploy_checks/feed_prerequisite_evidence_spec.rb`.
  *Code:* `PostDeployChecks::FeedPrerequisiteEvidence#call`.

- [x] **POST-DEPLOY-CHECK-009** — The system shall expose
  `post_deploy_checks:run` as the operator/deploy-pipeline entry point,
  accepting `PROJECT_ID`, `CHECK_KEY`, `DEPLOYED_REVISION`, and optionally
  `SOURCE_ISSUE_NUMBER` / `PREREQUISITE_NOTIFICATION_ID` /
  `PREREQUISITE_IDENTITY`, running under an explicit tenant context for the
  target project's account.
  *Tests:* manual/documented (rake tasks are not covered by this segment's
  automated suite; see `lib/tasks/post_deploy_checks.rake`).
  *Code:* `lib/tasks/post_deploy_checks.rake`.

- [x] **POST-DEPLOY-CHECK-010** — The `closed_agent_planning_hold_reconciliation_count`
  check shall count active `agent_planning_hold_reconciliation` notifications
  for the project whose subject issue's `github_state` is `"closed"`
  (baseline 36, target 0), scoped strictly to issues belonging to the
  authorized project, and distinguishing closed-source from open-source
  active notifications.
  *Tests:* `spec/services/post_deploy_checks/checks/closed_agent_planning_hold_reconciliation_count_spec.rb`.
  *Code:* `PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount`.

- [x] **POST-DEPLOY-CHECK-011** — When a check execution raises a
  non-retryable error, the system shall publish an immediate blocking
  `Notification` (`source: "post_deploy_check_execution_failed"`) naming the
  concrete recovery action; when it raises a retryable infrastructure error,
  the system shall publish a blocking `Notification`
  (`source: "post_deploy_check_persistent_failure"`) only after
  `PostDeployChecks::Run::PERSISTENT_FAILURE_THRESHOLD` (3) consecutive
  failed attempts for the same check and project, routing routine
  pending/running/successful/unknown-pending-deploy states to no escalation
  at all.
  *Tests:* `spec/services/post_deploy_checks/run_spec.rb`.
  *Code:* `PostDeployChecks::Run#escalate_now!`, `PostDeployChecks::Run#escalate_on_persistent_failure!`.
