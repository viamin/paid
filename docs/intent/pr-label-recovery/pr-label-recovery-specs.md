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

- [x] **PR-LABEL-RECOVERY-003** — When a terminal `create_pr` run from the
  last 30 days has a recorded branch but no PR identity, the hourly recovery
  SHALL query GitHub for an open PR with that exact owner-qualified head,
  restore run-to-PR linkage only for one unambiguous match, sync and link the
  local PR, and apply the ordinary label-recovery policy. It SHALL ignore
  queued, running, paused, rate-limited, and superseded retry runs plus
  ambiguous or absent matches, process at most 200 unlinked runs per sweep,
  and be idempotent on later sweeps.
  Before restoring a wholly missing Paid label set, recovery SHALL preserve a
  trusted user's explicit removal of either Paid ownership label.
  *Code:* `RecoverMissingPullRequestLabelsJob#recover_unlinked_runs`.
  *Test:* `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`.
  ("preserves manual opt-out").
