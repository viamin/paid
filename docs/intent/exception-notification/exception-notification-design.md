---
parent: PAID
prefix: EXCEPTION-NOTIFY
---

# Low-Level Design: Exception Notification

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the current shipped exception-capture path from RDR-039:
> `exception_notification`, the custom `Paid::ExceptionNotifier`, and the
> terminal-failure hook in `ApplicationJob`.

## Purpose

Paid already had an exception-incident pipeline, but without a global capture
surface most unhandled request/job failures never entered it. The shipped
solution uses `exception_notification` as the capture mechanism and a custom
notifier that serializes exceptions into `HandleExceptionJob`, which then feeds
 the existing incident pipeline asynchronously.

## Custom Notifier Contract

`Paid::ExceptionNotifier#call(exception, options = {})` is the adapter between
`exception_notification` and the incident pipeline.

It:

- resolves the tenant account from explicit `data[:account]` or `Current.account`
- returns `nil` without enqueueing when no account is available
- pins `subsystem` and `project_id` from the top-level data so nested context
  cannot overwrite them
- truncates exception messages to 10,000 characters and backtraces to 20 frames
- enqueues `HandleExceptionJob` instead of running the incident pipeline inline
- swallows its own internal errors and logs `exception_notifier.notify_failed`

The notifier never raises on behalf of the original failure.

## Rack and Job Capture Surfaces

`config/initializers/exception_notification.rb` registers the custom notifier
with `exception_notification` and inserts `ExceptionNotification::Rack` after
`ActionDispatch::ShowExceptions`, placing the notifier inside Rails exception
handling so request-time 500s are observed before the error page is rendered.

`ApplicationJob` is the background-job entry point. Its base
`rescue_from(StandardError)` reports only terminal failures
(`executions >= max_attempts`) through `notify_terminal_failure`, passing the
declared `notification_subsystem`, any `notification_project_id` override, and
the resolved tenant account. `HandleExceptionJob` is explicitly excluded to
avoid recursive notification loops.

## What this is not

- **Not synchronous incident handling.** The notifier enqueues
  `HandleExceptionJob`; it does not classify or file issues inline.
- **Not per-attempt job spam.** Non-terminal retries do not notify; only the
  terminal failure does.
- **Not a replacement for the downstream incident pipeline.** This segment
  covers capture and enqueueing only; incident classification, issue filing,
  and notification fan-out live in their own implementation path.
