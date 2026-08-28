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
