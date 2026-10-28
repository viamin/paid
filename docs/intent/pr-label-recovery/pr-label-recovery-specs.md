# EARS Specs: PR Label Recovery

> Testable claims for the label recovery safety net. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target across specs, tests, and code (`grep -r PR-LABEL-RECOVERY-001`).

- [x] **PR-LABEL-RECOVERY-001** — While a terminal agent run within the last
  24 hours created a pull request, the recovery job SHALL consider that run a
  candidate regardless of when the run was created, and SHALL re-apply the
  generated and automation labels when both are missing.
  *Code:* `RecoverMissingPullRequestLabelsJob#candidate_runs`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`.

- [x] **PR-LABEL-RECOVERY-002** — While a pull request still carries the
  generated label but is missing the automation label, the recovery job
  SHALL NOT re-add the automation label.
  *Code:* `RecoverMissingPullRequestLabelsJob#missing_labels`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`
  ("preserves manual opt-out").

- [x] **PR-LABEL-RECOVERY-003** — When a terminal `create_pr` run in the
  recovery window lacks a recorded PR number but its source issue is linked to
  an open locally synced PR in the same project, the recovery job SHALL use
  that link to recover missing labels once. It SHALL not infer ownership from
  PR text, labels, or repository-wide proximity.
  *Code:* `RecoverMissingPullRequestLabelsJob#recovery_candidates`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`.
