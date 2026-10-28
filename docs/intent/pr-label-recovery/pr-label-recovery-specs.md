# EARS Specs: PR Label Recovery

> Testable claims for the label recovery safety net. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target across specs, tests, and code (`grep -r PR-LABEL-RECOVERY-001`).

- [x] **PR-LABEL-RECOVERY-001** — While an agent run completed within the
  last 24 hours created a pull request, the recovery job SHALL consider that
  run a candidate regardless of when the run was created, and SHALL re-apply
  the generated and automation labels when both are missing.
  *Code:* `RecoverMissingPullRequestLabelsJob#candidate_runs`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`.

- [x] **PR-LABEL-RECOVERY-002** — While a pull request still carries the
  generated label but is missing the automation label, the recovery job
  SHALL NOT re-add the automation label.
  *Code:* `RecoverMissingPullRequestLabelsJob#missing_labels`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`
  ("preserves manual opt-out").

- [x] **PR-LABEL-RECOVERY-003** — When a failed, timed-out, or cancelled
  `create_pr` run terminated within the bounded recovery window without a
  recorded PR number, but its persisted branch identifies exactly one open PR
  in the project's own repository, recovery SHALL idempotently record the PR
  identity, sync and source-link the local PR, and apply the normal missing
  label policy. Zero or ambiguous matches SHALL not be linked or labeled.
  *Code:* `RecoverMissingPullRequestLabelsJob`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`.
