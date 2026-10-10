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
  (`github_sync.priority_labels_reconcile_failed`), not raised, so a transient
  GitHub failure does not fail the surrounding issue sync.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.reconcile_labels`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`.

- [x] **PRIORITY-LABEL-SYNC-005** — When a reconciliation fails with a
  `GithubClient::Error` or reports one or more failed priority-label removals,
  the system SHALL enqueue
  `Issues::SyncPriorityLabelsToPullRequestJob`, a bounded retry (polynomial
  backoff) that re-runs the same idempotent reconciliation — re-resolving the
  open Paid-created pull request and recomputing the label diff, so it no-ops
  once repaired — instead of leaving the pull request at a stale priority
  until the issue's priority labels change again (the issue's new labels are
  persisted before the reconciliation runs, so no later sync of the unchanged
  issue re-triggers the flow). When that bounded retry is exhausted, the
  system SHALL report the terminal failure to the issue's owning account.
  *Code:* `Issues::SyncPriorityLabelsToPullRequest.call`,
  `Issues::SyncPriorityLabelsToPullRequestJob`.
  *Test:* `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`,
  `spec/jobs/issues/sync_priority_labels_to_pull_request_job_spec.rb`.
