# EARS Specs: Priority Label Sync

> Testable claims for keeping a pull request's priority labels in sync with
> its linked issue's after the issue is re-triaged (#4249). Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target across specs, tests, and code (`grep -r PRIORITY-LABEL-SYNC-001`).

- [x] **PRIORITY-LABEL-SYNC-001** — While a non-pull-request issue's priority
  label set (its labels intersected with `project.priority_label_names`)
  changes during a GitHub sync, and the issue has an open pull request Paid
  created, the system SHALL reconcile that pull request's priority labels to
  match the issue's: add any priority label newly present on the issue and
  remove any priority label on the pull request the issue no longer carries.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.call`,
  `Issues::UpsertFromGithub.sync_priority_labels_to_pull_request`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`,
  `spec/services/issues/upsert_from_github_spec.rb`.

- [x] **PRIORITY-LABEL-SYNC-002** — Reconciliation SHALL run only when
  `project.inherit_priority_labels?` is true (which already folds in
  `UPSTREAM-GATE-002`'s upstream-mode check), and SHALL be a no-op when the
  issue has no open Paid-created pull request.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.call`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`.

- [x] **PRIORITY-LABEL-SYNC-003** — Reconciliation SHALL only ever add or
  remove labels present in `project.priority_label_names`; labels outside
  that set (human-added or otherwise) on either the issue or the pull
  request SHALL never be added, removed, or otherwise considered.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.label_diff`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`.

- [x] **PRIORITY-LABEL-SYNC-004** — A `GithubClient::Error` raised while
  applying the label changes SHALL be caught and logged
  (`github_sync.priority_labels_reconcile_failed`), not raised, so a
  transient GitHub failure does not fail the surrounding issue sync.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.reconcile_labels`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`.
