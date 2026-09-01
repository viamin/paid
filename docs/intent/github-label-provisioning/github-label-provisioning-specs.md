# EARS Specs: GitHub Label Provisioning

> Testable claims for the canonical GitHub label provisioning contract.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r GH-LABELS-001`).

- [x] **GH-LABELS-001** — `Projects::EnsureStandardLabels` SHALL provision,
  in one idempotent call, the complete canonical set of Paid-owned and
  built-in control labels: the four project-configurable labels,
  `recommend_close`, the `needs_input` stage mapping (when it diverges from
  `enhance_issue_needs_input_label_name`), `paused`, `escalated`,
  `dismiss_escalation`, `skip_auto_merge`, `auto_merged`,
  `auto_merged_dependabot`, `auto_released`, `paid_ready`, `model_health`,
  the three TDD gate labels, the priority tiers, and the project's effective
  auto-pick skip labels — creating any that are missing.
  *Code:* `app/services/projects/ensure_standard_labels.rb#expected_labels`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`.

- [x] **GH-LABELS-002** — When an existing Paid-owned label's color or
  description diverges from its canonical definition, `EnsureStandardLabels`
  SHALL reconcile it via a GitHub label update (`GithubClient#update_label`)
  rather than only reporting the divergence, and SHALL record a permission
  failure on that update as an actionable error rather than leaving the
  label silently stale.
  *Code:* `app/services/projects/ensure_standard_labels.rb#reconcile_divergence`,
  `app/services/github_client.rb#update_label`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`,
  `spec/services/github_client_spec.rb`.

- [x] **GH-LABELS-003** — Every canonical label definition SHALL carry a
  description that states the consequence of applying or removing the label
  in plain language, fit within GitHub's 100-character label description
  limit, and be tagged with exactly one `kind` (`:control`, `:status`, or
  `:informational`) reflecting whether applying/removing it changes
  automation, marks Paid-applied output, or is purely informational.
  *Code:* `app/services/projects/ensure_standard_labels.rb::LABEL_DEFINITIONS`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`.

- [x] **GH-LABELS-004** — `EnsureStandardLabels` SHALL resolve every
  project-configurable label name (generated, automation, enhance-issue
  pair, recommend_close, the needs_input stage mapping, priority tiers,
  auto-pick skip labels) from the project's own settings, and SHALL NOT
  create or modify any repository label outside its canonical set, so
  custom label names keep working and unrelated user-owned taxonomy labels
  are never overwritten.
  *Code:* `app/services/projects/ensure_standard_labels.rb#expected_labels`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`
  ("custom priority label names", "custom auto-pick skip label",
  "custom recommend_close label", "unrelated, non-canonical labels").

- [x] **GH-LABELS-005** — A failed label read (403) SHALL raise a
  `GithubClient::ApiError` with an actionable message instead of returning a
  partial result, and a failed per-label create or reconcile (403) SHALL be
  recorded in `Result#errors` so `Result#any_errors?` lets a caller detect
  the failure before depending on the label existing. Runtime call sites that
  need a specific control label to exist before mutating local state SHALL bail
  out when `Result#any_errors?` is true rather than claiming the state change
  succeeded locally without a matching GitHub label.
  *Code:* `app/services/projects/ensure_standard_labels.rb`,
  `app/temporal/activities/mark_escalated_activity.rb`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`,
  `spec/temporal/activities/mark_escalated_activity_spec.rb`.

- [x] **GH-LABELS-006** — The escalation control labels
  (`paid-escalated`, `paid-dismiss-escalation`) SHALL be defined exactly
  once, as `Issue::ESCALATED_LABEL` and `Issue::DISMISS_ESCALATION_LABEL`,
  and every activity/service that reads or writes them SHALL reference
  those constants rather than repeating the literal string.
  *Code:* `app/models/issue.rb`, `app/temporal/activities/mark_escalated_activity.rb`,
  `app/temporal/activities/fetch_issues_activity.rb`,
  `app/temporal/activities/merge_pull_request_activity.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/services/pull_requests/unblock.rb`.
  *Test:* `spec/models/issue_spec.rb`, `spec/services/pull_requests/unblock_spec.rb`,
  `spec/temporal/activities/mark_escalated_activity_spec.rb`.

- [x] **GH-LABELS-007** — `EnsureStandardLabels` SHALL detect label-name
  collisions across the canonical categories (case-insensitively) before
  making any GitHub API call, record one actionable `Result#errors` entry
  per colliding name listing every category that claims it, and SHALL NOT
  create or reconcile the colliding label (so the later definition cannot
  silently overwrite the earlier definition's color/description). Detection
  covers configured-vs-configured, configured-vs-fixed, configured-vs-TDD,
  configured-vs-auto-pick-skip, configured-vs-priority, and
  within-category duplicates such as two priority tiers mapping to the
  same name.
  *Code:* `app/services/projects/ensure_standard_labels.rb#call`,
  `app/services/projects/ensure_standard_labels.rb#detect_label_collisions`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`
  ("configured label name collides with a fixed category label",
  "case-insensitive configured name collision",
  "two priority tiers map to the same label name").

- [x] **GH-LABELS-008** — When a label create returns 422,
  `EnsureStandardLabels` SHALL treat it as a lost create race only after a
  follow-up single-label fetch confirms the label now exists (recorded in
  `Result#existing`); an unconfirmed 422 — a validation failure on the name
  or description, or a verification fetch that itself fails — SHALL be
  recorded in `Result#errors` so callers that gate on `any_errors?` never
  proceed without the control label existing. Symmetrically, when a
  reconcile update returns 404 because another writer deleted the label
  mid-sync, the failure SHALL be recorded in `Result#errors` rather than
  aborting the remaining labels' sync.
  *Code:* `app/services/projects/ensure_standard_labels.rb#create_label`,
  `app/services/projects/ensure_standard_labels.rb#reconcile_divergence`,
  `app/services/github_client.rb#label`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`
  ("422 race", "422 create failure is a validation failure",
  "post-422 verification fetch itself fails",
  "deleted between fetch and update"),
  `spec/services/github_client_spec.rb`.
