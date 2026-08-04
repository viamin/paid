# EARS Specs: Account Queue Fairness

> Testable claims for account-scoped queue-fairness selection. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r ACCOUNT-QUEUE-001`).

- [x] **ACCOUNT-QUEUE-001** — When the dashboard previews queued work for a
  fair-share account, the system SHALL interleave visible queued runs by
  dispatch order instead of clustering one project's backlog at the top so the
  preview reflects the current cross-project fair-share policy.
  *Code:* `app/services/dashboard/queue_preview.rb`.
  *Test:* `spec/services/dashboard/queue_preview_spec.rb`.

- [ ] **ACCOUNT-QUEUE-002** — When an account sets
  `tenant_settings.queue_fairness_mode` to `strict_priority`, the scheduler
  SHALL order queued runs by global queue priority before project/user active
  counts so a higher-priority run in a busy project can preempt lower-priority
  work in an idle project.

- [ ] **ACCOUNT-QUEUE-003** — When queue fairness mode changes, the dashboard
  queue preview and queue-order messaging SHALL use the same resolved mode as
  scheduler dequeue so the UI does not promise fair-share ordering for an
  account that chose strict priority.

- [ ] **ACCOUNT-QUEUE-004** — When `strict_priority` mode is enabled, Temporal
  workflow dispatch SHALL not reapply per-account fair-share after SQL dequeue
  claims a run.

- [D] **ACCOUNT-QUEUE-005** — The system MAY later support weighted or
  deficit-round-robin policies, but binary `fair_share` versus
  `strict_priority` mode is the only queue-fairness contract in scope for this
  segment today.
