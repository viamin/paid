# EARS Specs: Post-Deploy Measurements

> Testable claims for collecting trusted live post-deploy measurements as
> closeout evidence (#4907, measuring #4812's acceptance). Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target (`grep -r POST-DEPLOY-001`).

- [x] **POST-DEPLOY-001** — When Paid selects a post-deploy check, it SHALL
  resolve it exclusively from a code-reviewed registry keyed by stable check
  key and integer version carrying the criterion, expected baseline, target
  count, and required capabilities; an unknown key or superseded version
  SHALL be rejected with a named recovery action rather than executed or
  guessed. No operator-supplied SQL or command SHALL reach execution.
   *Code:* `app/services/post_deploy_measurements/registry.rb`,
   `app/controllers/projects/post_deploy_measurements_controller.rb`,
   `config/routes.rb`.
   *Test:* `spec/services/post_deploy_measurements/registry_spec.rb`,
   `spec/requests/projects/post_deploy_measurements_spec.rb`.

- [x] **POST-DEPLOY-002** — When the #4812 check runs, it SHALL count, within
  the authorized account and a recorded project scope, active
  `agent_planning_hold_reconciliation` notifications whose subject issue is
  closed (resolving `AgentRun` subjects through their issue), excluding
  resolved or dismissed rows, and SHALL record `actionable_closed_source`,
  `active_open_source`, `active_total`, `resolved_total`, and the
  project/account scope so a zero is interpretable; the expected baseline
  (36) and target (0) SHALL be recorded with the evidence. A development
  snapshot or merged-PR state SHALL NOT be treated as the measured result.
  *Code:* `app/services/post_deploy_measurements/checks/planning_hold_notifications.rb`.
  *Test:* `spec/services/post_deploy_measurements/checks/planning_hold_notifications_spec.rb`.

- [x] **POST-DEPLOY-003** — When a check executes, it SHALL first resolve the
  deployment target from the issue's terminal closeout evidence; with no
  merged PR marked deployed the measurement SHALL remain `awaiting_deployment`
  with a concrete recovery action and SHALL NOT record a pass or escalate.
  Execution SHALL occur only after the target revision (`pr-<number>@<deployed_at>`)
  is deployed.
  *Code:* `app/services/post_deploy_measurements/deployment_target.rb`,
  `app/services/post_deploy_measurements/execute.rb`.
  *Test:* `spec/services/post_deploy_measurements/execute_spec.rb`.

- [x] **POST-DEPLOY-004** — When a measurement is requested or executed, Paid
  SHALL persist an idempotent attempt/evidence record bound to issue,
  criterion, check key and version, deployed revision, account and project,
  execution time, duration, counts, status, and failure/unknown reason;
  duplicate requests and events SHALL converge on the existing row, retries
  SHALL increment a bounded attempts counter, and a superseded deployed
  revision or check version SHALL require a fresh record rather than reusing
  stale evidence. A partial result SHALL NOT be recorded as a pass.
  *Code:* `app/models/post_deploy_measurement.rb`,
  `app/services/post_deploy_measurements/request.rb`,
  `app/services/post_deploy_measurements/execute.rb`.
   *Test:* `spec/services/post_deploy_measurements/request_spec.rb`,
   `spec/services/post_deploy_measurements/execute_spec.rb`,
   `spec/models/post_deploy_measurement_spec.rb`,
   `spec/requests/projects/post_deploy_measurements_spec.rb`.

- [x] **POST-DEPLOY-005** — When a check runs, it SHALL execute only
  read-only, bounded count queries inside a database-enforced read-only
  transaction, under the measurement's tenant context with normal row-level
  security and database-role rules, and SHALL NOT read notifications,
  issues, or agent runs of another account or project.
  *Code:* `app/services/post_deploy_measurements/execute.rb`,
  `app/services/post_deploy_measurements/checks/planning_hold_notifications.rb`.
  *Test:* `spec/services/post_deploy_measurements/checks/planning_hold_notifications_spec.rb`,
  `spec/services/post_deploy_measurements/execute_spec.rb`.

- [x] **POST-DEPLOY-006** — When a current, passing measurement exists for a
  bound prerequisite occurrence, Paid SHALL record machine-collected
  sufficient evidence for exactly that occurrence on the existing
  `partial_closeout.prerequisite` notification and SHALL resolve the
  notification only when all its occurrences are satisfied, marking
  `released_by: "post_deploy_measurement"`. A passing measurement SHALL NOT
  attest whole-issue completion, release an unbound or superseded occurrence,
  or bypass an unrelated human decision.
  *Code:* `app/services/post_deploy_measurements/reconcile_result.rb`.
  *Test:* `spec/services/post_deploy_measurements/reconcile_result_spec.rb`.

- [x] **POST-DEPLOY-007** — When a measurement is `pending`, `running`,
  `awaiting_deployment`, or `passed`, Paid SHALL surface it on the
  partial-closeout progress/closeout surfaces without creating an Action
  Required item. Paid SHALL escalate — as a non-blocking notification with an
  exact recommended action — only missing capability or check definition,
  execution-time authorization failure, persistent execution failure after
  the attempt cap, or a contradictory measured result; escalation SHALL NOT
  fabricate a human evidence task.
   *Code:* `app/services/post_deploy_measurements/execute.rb`,
   `app/views/dashboard/_inbox_detail_partial_closeout.html.erb`.
   *Test:* `spec/services/post_deploy_measurements/execute_spec.rb`,
   `spec/requests/inbox_spec.rb`.

- [x] **POST-DEPLOY-008** — When a measurement's release resolves a
  prerequisite notification, the existing partial-closeout re-enqueue and
  Inbox cache refresh SHALL fire so count and queue surfaces reflect the
  release without a reload.
  *Code:* `app/models/notification.rb`,
  `app/services/post_deploy_measurements/reconcile_result.rb`.
  *Test:* `spec/services/post_deploy_measurements/reconcile_result_spec.rb`.

- [x] **POST-DEPLOY-009** — When measurements are due, retry-eligible, or
  bound to a moved deployment revision, the bounded sweep SHALL re-evaluate
  and enqueue them under their own tenant context while their prerequisite
  occurrence is still active, and SHALL stop re-requesting evidence whose
  prerequisite is already released.
  *Code:* `app/jobs/post_deploy_measurement_sweep_job.rb`,
  `app/jobs/post_deploy_measurement_job.rb`.
  *Test:* `spec/jobs/post_deploy_measurement_sweep_job_spec.rb`,
  `spec/jobs/post_deploy_measurement_job_spec.rb`.
