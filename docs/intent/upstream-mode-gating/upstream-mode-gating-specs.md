# EARS Specs: Upstream-Mode Gating

> Testable claims for the server-side enforcement of upstream-mode feature
> restrictions (#4078): when a Paid project opens pull requests against an
> upstream repository (a third-party repo Paid does not control), every
> PR-side automation is hard-disabled — no reviews, auto-merge, PR
> labeling, screenshot capture, or PR-side activation label can act on
> those PRs.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r UPSTREAM-GATE-001`).

- [x] **UPSTREAM-GATE-001** — `Project::UpstreamAutomation::DISABLED_FEATURES`
  SHALL be the canonical disable set for upstream mode and SHALL contain
  exactly `:pr_reviews`, `:auto_merge`, `:auto_release`, `:auto_scan_prs`,
  `:auto_fix_merge_conflicts`, `:pr_labeling`, `:owner_review_requests`,
  `:draft_review_rounds`, and `:screenshots`. `#upstream_automation_allowed?`
  SHALL return false for each of those features when the project targets
  PRs upstream, true for any feature outside that set, and SHALL be true
  for every feature on `own_repo` projects. The set lives in exactly one
  place so every gated feature consults the concern instead of reading
  `pr_target` directly.
  *Code:* `app/models/concerns/project/upstream_automation.rb`.
  *Test:* `spec/models/concerns/project/upstream_automation_spec.rb`.

- [x] **UPSTREAM-GATE-002** — `#upstream_pr_target?` SHALL be true only
  when `pr_target == "upstream"` AND `upstream_owner` AND `upstream_repo`
  are present; otherwise false. Every PR-side feature predicate on `Project`
  (`review_enabled?`, `review_bot_request_login`, `review_bot_request_chain`,
  `auto_merge_enabled?`, `auto_merge_dependabot?`, `auto_merge_bot_authored?`,
  `auto_release_enabled?`, `pr_auto_labels_enabled?`, `inherit_priority_labels?`,
  `auto_fix_merge_conflicts?`, `screenshots_enabled?`, the Dependabot auto-merge
  path, the scan-PRs activity, the request-review activity, the
  create-pull-request / create-aggregated-pull-request label handling,
  and the merge-pull-request path) SHALL short-circuit to its gated
  disabled result via `upstream_feature_enabled?` while upstream mode is
  active, regardless of any stored setting value. `RecoverMissingPullRequestLabelsJob`
  SHALL skip PRs opened in the upstream repository entirely, never
  re-adding labels to PRs Paid does not own.
  *Code:* `app/models/project.rb`, `app/jobs/recover_missing_pull_request_labels_job.rb`,
  `app/services/automation/feature_activation.rb`,
  `app/temporal/activities/capture_screenshots_activity.rb`,
  `app/temporal/activities/create_aggregated_pull_request_activity.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`,
  `app/temporal/activities/merge_pull_request_activity.rb`,
  `app/temporal/activities/request_review_activity.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Test:* `spec/models/concerns/project/upstream_automation_spec.rb`,
  `spec/services/automation/feature_activation_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **UPSTREAM-GATE-003** — `#upstream_feature_enabled?` SHALL return
  true when `upstream_automation_allowed?` is true, and SHALL return false
  while logging exactly one `upstream_mode_skipped` info event per
  `(project, feature)` pair when upstream mode disables `feature`. The log
  payload SHALL include `message: "upstream_mode_skipped"`, `project_id`,
  and `feature` (string). The memoization SHALL survive multiple
  consultations within the same project instance so a run that polls a
  gated predicate repeatedly does not flood the log, and SHALL NOT log at
  all for `own_repo` projects.
  *Code:* `app/models/concerns/project/upstream_automation.rb`.
  *Test:* `spec/models/concerns/project/upstream_automation_spec.rb`.

- [x] **UPSTREAM-GATE-004** — While a project's `pr_target` is `"upstream"`,
  `upstream_mode_automation_settings_valid` SHALL reject any save that
  would leave a gated feature enabled: `auto_merge_mode` (anything other
  than `"off"`), `allow_bot_authored_pr_auto_merge` true, `auto_release_granularity`
  (anything other than `"off"`), `review_settings` whose top-level toggle
  is true OR whose `methods.*.enabled` sub-flag is true, `auto_add_labels_enabled`
  true, `inherit_priority_labels` true, `owner_reviewer_login` present,
  `auto_fix_merge_conflicts` true, and `screenshot_settings` whose top-level
  toggle is true. A `pr_target` of `"upstream"` without a configured
  `upstream_owner` and `upstream_repo` SHALL also be rejected
  (`upstream_target_requires_upstream_repo`). Switching `pr_target` back
  to `"own_repo"` SHALL clear the gate and restore normal validation
  behavior so the previously-stored gated values can be saved.
  `ProjectsController#toggle_auto_merge` SHALL redirect with an alert
  and SHALL NOT cycle `auto_merge_mode` when the project targets PRs
  upstream, so the toggle cannot turn auto-merge on in upstream mode
  even before the validation fires.
  *Code:* `app/models/concerns/project/upstream_automation.rb`,
  `app/controllers/projects_controller.rb`.
  *Test:* `spec/models/concerns/project/upstream_automation_spec.rb`,
  `spec/requests/projects_spec.rb`.

- [x] **UPSTREAM-GATE-005** — `Tools::UpdateProjectSettings` SHALL slice
  the inbound settings to `PERMITTED_ATTRIBUTES` and SHALL then call
  `project.upstream_gated_setting_violations(attrs)`. If any returned
  violation would enable a gated feature while the project targets PRs
  upstream, the tool SHALL raise `ArgumentError` whose message includes
  the offending key names and SHALL NOT perform the save. The same
  `upstream_gated_setting_violations` predicate SHALL be the single
  source of truth for what counts as an enabling value, shared between
  the model validation and the chat path, so the form's disabled inputs
  cannot be bypassed through chat.
  *Code:* `app/models/concerns/project/upstream_automation.rb`,
  `app/mcp/tools/update_project_settings.rb`.
  *Test:* `spec/models/concerns/project/upstream_automation_spec.rb`,
  `spec/mcp/tools/update_project_settings_spec.rb`.
