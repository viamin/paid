# EARS Specs: Notification Severity Taxonomy

> Testable claims for the severity-classification gate and badge-scope change
> from issue #3720. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r NOTIFICATION-SEVERITY-001`).

- [x] **NOTIFICATION-SEVERITY-001** — When `Anomalies::Detect` publishes an
  `agent_run_anomaly` notification, the system SHALL always classify it
  `info`, regardless of whether the underlying anomalies are `warning` or
  `critical` severity.
  *Code:* `app/services/anomalies/detect.rb#notification_severity`.
  *Test:* `spec/services/anomalies/detect_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-002** — When `Scaling::QueueAlert` publishes a
  `queue_monitor` notification, the system SHALL always classify it `info`,
  regardless of whether the triggering alert is `warning` or `critical`
  severity.
  *Code:* `app/services/scaling/queue_alert.rb#publish_notification`.
  *Test:* `spec/services/scaling/queue_alert_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-003** — When
  `Notifications::Rules::ZeroIterationTimeout` publishes a
  `zero_iteration_timeout` notification, the system SHALL classify it
  `warning` (not `error`), reflecting that the platform-bug signal routes to
  an automatic handling path rather than requiring direct user action.
  *Code:* `app/services/notifications/rules/zero_iteration_timeout.rb#build`.
  *Test:* `spec/services/notifications/rules/zero_iteration_timeout_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-004** — When computing the bell-badge unread
  count — whether for a full render or for a Turbo-stream bell replacement
  broadcast after publish/resolve — the system SHALL count only active,
  unread notifications with severity `warning` or `error`; `info`
  notifications SHALL NOT contribute to the badge count.
  *Code:* `app/models/notification.rb` (`.badging` scope),
  `app/helpers/notifications_helper.rb#unread_notification_count`,
  `app/services/notifications/broadcasting.rb`.
  *Test:* `spec/models/notification_spec.rb`, `spec/helpers/notifications_helper_spec.rb`,
  `spec/services/notifications/publish_spec.rb`, `spec/services/notifications/resolve_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-005** — The notifications index page SHALL
  continue to list and allow filtering by `info`-severity notifications; the
  badge-scope change SHALL NOT alter which notifications are visible or
  filterable on that page.
  *Code:* `app/controllers/notifications_controller.rb`,
  `app/views/notifications/index.html.erb`.
  *Test:* `spec/requests/notifications_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-006** — The bell dropdown's "Mark all read"
  button visibility SHALL be driven by whether any active, unread
  notification exists (any severity, including `info`), independent of the
  badge count. Restricting the badge to `warning`/`error` (SEVERITY-004)
  SHALL NOT hide the bulk-read action when only `info` notifications are
  unread, since the dropdown itself still lists them.
  *Code:* `app/helpers/notifications_helper.rb#unread_notifications?`,
  `app/views/notifications/_bell.html.erb`,
  `app/services/notifications/broadcasting.rb`.
  *Test:* `spec/helpers/notifications_helper_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-007** — When a notification is persisted with
  `blocking: true`, the system SHALL require severity `error`, SHALL expose
  the row through `Notification.blocking`, and SHALL default its action URL
  to `/inbox/action_required:<notification.id>` when the publisher does not
  provide a more specific action target.
  *Code:* `app/models/notification.rb`, `app/services/notifications/publish.rb`.
  *Test:* `spec/models/notification_spec.rb`,
  `spec/services/notifications/publish_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-008** — When a signed-in user can see an active,
  blocking notification in their notification scope, the operator inbox SHALL
  derive an `action_required` entry from that notification with
  `waiting_since` set to the notification `created_at`, and SHALL remove the
  entry automatically when the notification resolves or is dismissed.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/policies/notification_policy.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`,
  `spec/services/inbox/count_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-009** — When the inbox renders an
  `action_required` entry, the detail pane SHALL show the notification's
  remediation guidance from metadata, using `recommended_action` as the
  canonical field and rendering any ordered `remediation_steps` inline.
  *Code:* `app/views/inbox/index.html.erb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`,
  `app/views/dashboard/_inbox_detail_action_required.html.erb`.
  *Test:* `spec/requests/inbox_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-010** — Publishers whose halted work cannot
  self-resolve SHALL set `blocking: true` at publish time, including
  `quality_auto_resume_cooldown`, `pr_followup_limit_reached`, and
  `guardrail_token_budget` on PR-continuation runs; self-resolving quota
  errors SHALL remain notification-only.
  *Code:* `app/services/quality_pause/auto_resume.rb`,
  `app/services/notifications/rules/pr_followup_limit_reached.rb`,
  `app/services/guardrails/violation_handler.rb`.
  *Test:* `spec/services/quality_pause/auto_resume_spec.rb`,
  `spec/services/notifications/rules/pr_followup_limit_reached_spec.rb`,
  `spec/services/guardrails/violation_handler_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-011** — When a subscription runner's managed
  authentication becomes ineligible with reason `credential_expired`,
  `credential_refresh_failed`, or `managed_auth_missing`, the system SHALL
  publish one active notification with severity `error`, `blocking: true`,
  runner-edit remediation metadata, and an action URL to that runner's edit
  page; when the runner becomes eligible again, the system SHALL auto-resolve
  the notification.
  *Code:* `app/services/notifications/rules/runner_subscription_auth_ineligible.rb`,
  `app/jobs/notifications/check_runner_quotas_job.rb`.
  *Test:* `spec/services/notifications/rules/runner_subscription_auth_ineligible_spec.rb`,
  `spec/jobs/notifications/check_runner_quotas_job_spec.rb`.

- [x] **NOTIFICATION-SEVERITY-012** — Blocking PR notifications SHALL include
  concrete remediation metadata for the inbox detail pane: `pr_followup_limit_reached`
  SHALL carry the run count, configured limit, PR URL, and a manual-takeover
  recommendation; `guardrail_token_budget` on PR-continuation runs SHALL carry
  PR-budget remediation guidance that tells the operator to review output so far
  or raise the relevant token budget.
  *Code:* `app/services/notifications/rules/pr_followup_limit_reached.rb`,
  `app/services/guardrails/violation_handler.rb`.
  *Test:* `spec/services/notifications/rules/pr_followup_limit_reached_spec.rb`,
  `spec/services/guardrails/violation_handler_spec.rb`.
