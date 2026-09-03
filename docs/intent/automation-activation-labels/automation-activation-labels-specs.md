# EARS Specs: Automation Activation Labels

> Testable claims for per-item additive automation activation labels.
> Status markers: `[ ]` active gap · `[x]` implemented · `[D]` deferred.

- [x] **AUTOMATION-ACTIVATION-001** — `Project`, `UserSetting`, and
  `TenantSetting` SHALL each persist an optional `feature_activation_labels`
  JSONB map whose effective value resolves project override → owner
  user-setting override → tenant override → built-in defaults, mirroring the
  existing `auto_pick_skip_labels` override chain. `nil` SHALL mean inherit; an
  empty hash SHALL mean an explicit override with no activation labels.
  *Code:* `app/models/concerns/feature_activation_labels.rb`,
  `app/models/project.rb`, `app/models/user_setting.rb`,
  `app/models/tenant_setting.rb`,
  `db/migrate/<ts>_add_feature_activation_labels_to_tenant_settings_user_settings_and_projects.rb`.
  *Test:* `spec/models/project_spec.rb`.

- [x] **AUTOMATION-ACTIVATION-002** — `Projects::EnsureStandardLabels` SHALL
  provision the resolved activation labels alongside the existing standard
  labels, under a new `kind: :activation`, creating missing labels and
  reconciling drift by configured name rather than hard-coded literal.
  *Code:* `app/services/projects/ensure_standard_labels.rb`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`.

- [x] **AUTOMATION-ACTIVATION-003** — When a project-level automation setting
  is off, the corresponding issue or pull request activation label SHALL enable
  only that labeled work item for the scoped feature; when the project-level
  setting is already on, the activation label SHALL be a no-op and SHALL NOT
  convert the project into an allowlist.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/temporal/activities/scan_security_alerts_activity.rb`,
  `app/temporal/activities/evaluate_auto_release_activity.rb`,
  `app/jobs/auto_release_evaluation_job.rb`,
  `app/jobs/dependabot_auto_merge_job.rb`.
  *Test:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/services/automation/pull_request_evaluator_spec.rb`,
  `spec/temporal/activities/scan_security_alerts_activity_spec.rb`,
  `spec/temporal/activities/evaluate_auto_release_activity_spec.rb`,
  `spec/jobs/auto_release_evaluation_job_spec.rb`.

- [x] **AUTOMATION-ACTIVATION-004** — Issue-scoped activation SHALL respect
  the existing subtractive skip labels first: if an issue carries any effective
  auto-pick skip label, activation labels (including `paid-in-full`) SHALL NOT
  queue work for that issue.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`.
  *Test:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/temporal/activities/detect_labels_activity_spec.rb`.

- [x] **AUTOMATION-ACTIVATION-005** — Specific activation labels SHALL override
  the `paid-in-full` catchall for the same feature on the same work item. In
  particular, `paid-tdd-auto` SHALL override `paid-in-full`'s strict TDD
  default and select non-strict TDD instead.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/models/agent_run.rb`, `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Test:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/models/agent_run_spec.rb`.

- [x] **AUTOMATION-ACTIVATION-006** — Every activation label SHALL be honored
  only when `Automation::LabelPolicy` confirms that a project-trusted GitHub
  user added that activating label to the issue or pull request. A trusted issue
  creator alone SHALL NOT authorize a newly added activation label.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`.
  *Test:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/temporal/activities/scan_security_alerts_activity_spec.rb`,
  `spec/jobs/auto_release_evaluation_job_spec.rb`.
