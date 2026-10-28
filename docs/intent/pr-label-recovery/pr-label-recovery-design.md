# LLD: PR Label Recovery

> parent: docs/high-level-design.md
> prefix: PR-LABEL-RECOVERY

## Problem

`CreatePullRequestActivity` labels newly created pull requests best-effort.
When post-processing fails or is interrupted after the agent opened the PR,
the run can also terminate without its PR number. Either failure leaves the PR
without `paid-generated` / `paid-automation`, which drops it out of Paid
automation.

## Design

`RecoverMissingPullRequestLabelsJob` (GoodJob cron, hourly) re-applies missing
labels to PRs created by completed `create_pr` agent runs:

- **Candidate window**: runs **completed** in the last 24 hours. PRs are
  opened at run completion, so the window must track `completed_at`, not
  `created_at` — a multi-day run would otherwise age out of the window before
  its PR ever exists.
- **Opt-out preserved**: if the PR still has the generated label but is
  missing the automation label, assume a human removed it intentionally and
  do not re-add.
- **Priority inheritance**: missing priority labels are backfilled even when
  auto-add labels is disabled.
- **Interrupted publication**: terminal create-PR runs in the same bounded
  window that have no PR number are matched by their persisted branch against
  open PRs in the project's own repository. Exactly one match restores the
  run identity and local PR/source link before normal label recovery; zero or
  multiple matches remain untouched rather than guessing.

## Code

`app/jobs/recover_missing_pull_request_labels_job.rb`
Test: `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`
