# EARS Specs: Exception Notification

> Testable claims for the shipped exception-notification capture path from
> RDR-039. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r EXCEPTION-NOTIFY-001`).

- [x] **EXCEPTION-NOTIFY-001** — When the custom exception notifier receives
  an exception and an account is available, it SHALL enqueue `HandleExceptionJob`
  with the serialized exception class, a message truncated to 10,000
  characters, a backtrace truncated to 20 frames, and pinned subsystem/project
  context.
  *Code:* `lib/paid/exception_notifier.rb`.
  *Test:* `spec/lib/paid/exception_notifier_spec.rb`.

- [x] **EXCEPTION-NOTIFY-002** — When the custom notifier has no account
  context, it SHALL return `nil` without enqueueing; and when the notifier
  itself fails internally, it SHALL swallow that failure and log
  `exception_notifier.notify_failed`.
  *Code:* `lib/paid/exception_notifier.rb`.
  *Test:* `spec/lib/paid/exception_notifier_spec.rb`.

- [x] **EXCEPTION-NOTIFY-003** — `ApplicationJob` SHALL notify terminal
  background-job failures through `Paid::ExceptionNotifier` using the job's
  declared subsystem/project context, SHALL skip notification on non-terminal
  retries, and SHALL never notify recursively for `HandleExceptionJob`.
  *Code:* `app/jobs/application_job.rb`.
  *Test:* `spec/jobs/application_job_spec.rb`,
  `spec/integration/exception_notification_integration_spec.rb`.

- [x] **EXCEPTION-NOTIFY-004** — The request capture surface SHALL register
  the custom notifier with `ExceptionNotification::Rack` so a web-request
  exception can be attributed to `Current.account` and converted into a queued
  `HandleExceptionJob`.
  *Code:* `config/initializers/exception_notification.rb`.
  *Test:* `spec/integration/exception_notification/rack_spec.rb`.
