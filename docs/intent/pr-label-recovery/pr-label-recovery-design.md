# LLD: PR Label Recovery

> parent: docs/high-level-design.md
> prefix: PR-LABEL-RECOVERY

## Problem

`CreatePullRequestActivity` labels newly created pull requests best-effort.
When that call fails transiently (GitHub API error), the PR is left without
`paid-generated` / `paid-automation`, which drops it out of Paid automation.

## Design

`RecoverMissingPullRequestLabelsJob` (GoodJob cron, hourly) re-applies missing
labels to PRs created by terminal `create_pr` agent runs, including runs that
failed, timed out, or were cancelled after GitHub accepted the PR:

- **Candidate window**: terminal runs whose completion timestamp, or update
  timestamp when completion is missing, falls within the last 30 days. The
  bounded sweep covers post-publication failures while avoiding an unbounded
  historical scan.
- **Missing linkage**: when a terminal run has no recorded PR number but has a
  branch, the job looks up an open PR for that exact repository-qualified head.
  Exactly one match repairs the run's number and URL before normal local sync
  and label recovery. Zero or ambiguous matches record an attempt and are
  retried no more than once per day, bounding GitHub API use for branches that
  never produced an open PR. This is mechanical branch evidence, not a
  title/body heuristic.
- **Opt-out preserved**: if the PR still has the generated label but is
  missing the automation label, assume a human removed it intentionally and
  do not re-add.
- **Priority inheritance**: missing priority labels are backfilled even when
  auto-add labels is disabled.

## Code

`app/jobs/recover_missing_pull_request_labels_job.rb`
Test: `spec/jobs/recover_missing_pull_request_labels_job_spec.rb`
