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

- [x] **PR-LABEL-RECOVERY-003** — While a locally synced open pull request was
  linked to a source issue but failure, timeout, cancellation, retry, or
  interrupted post-processing left its terminal `create_pr` run without a PR
  number, the hourly recovery job SHALL inspect at most 500 PRs created within
  seven days and SHALL repair the run-to-PR number and URL only for a unique
  source/run match. Recovery SHALL be idempotent, SHALL leave ambiguous
  matches untouched, and SHALL NOT restore missing automation labels solely
  because linkage was repaired. The repaired agent-owned linkage SHALL admit
  the PR to normal scanning so existing bounded stall detection can distinguish
  active work, ordinary CI/review waits, and stopped execution.
  *Code:* `PullRequests::RecoverMissingLinkage#call`,
  `Activities::ScanPaidPrsActivity#activation_scannable_prs`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
