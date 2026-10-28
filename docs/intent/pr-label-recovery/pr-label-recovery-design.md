# LLD: PR Label Recovery

> parent: docs/high-level-design.md
> prefix: PR-LABEL-RECOVERY

## Problem

`CreatePullRequestActivity` labels newly created pull requests best-effort.
When that call fails transiently (GitHub API error), the PR is left without
`paid-generated` / `paid-automation`, which drops it out of Paid automation.

## Design

`RecoverMissingPullRequestLabelsJob` (GoodJob cron, hourly) re-applies missing
labels to PRs created by `create_pr` agent runs:

- **Candidate window**: runs **completed** in the last 24 hours. PRs are
  opened at run completion, so the window must track `completed_at`, not
  `created_at` — a multi-day run would otherwise age out of the window before
  its PR ever exists.
- **Opt-out preserved**: if the PR still has the generated label but is
  missing the automation label, assume a human removed it intentionally and
  do not re-add.
- **Priority inheritance**: missing priority labels are backfilled even when
  auto-add labels is disabled.
- **Interrupted finalization**: terminal failed, timed-out, cancelled, or
  otherwise interrupted runs from a bounded 30-day window that have a branch
  but no recorded PR number are matched to an open PR only through GitHub's
  exact owner-qualified head-branch filter. An unambiguous match restores the
  run's PR identity, syncs the local PR, and then uses the same label recovery
  path. Running, paused, queued, rate-limited, and superseded retry work and
  ambiguous matches are never claimed. Repeated sweeps are idempotent because
  repaired runs leave the unlinked candidate scope.
- **Human opt-out**: recovery consults trusted GitHub label history before
  restoring a wholly missing Paid label set. A trusted removal is preserved;
  absence without trusted removal evidence remains recoverable because the
  original post-processing call may never have succeeded.

## Code

`app/jobs/recover_missing_pull_request_labels_job.rb`
Test: `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`
