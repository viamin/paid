# LLD: Priority Label Sync

> parent: docs/high-level-design.md
> prefix: PRIORITY-LABEL-SYNC

## Problem

`CreatePullRequestActivity#inherited_priority_labels` and
`CreateAggregatedPullRequestActivity#add_pr_labels` copy an issue's priority
label (`project.priority_label_names & issue.labels`) onto its pull request
once, at PR creation. If the issue is re-triaged afterward (`P2` → `P1`, or
priority removed), the linked PR keeps the stale label forever — nothing
reacts to an issue label *change*. Anything that reads PR priority (e.g. the
quality-gate priority bypass) then sees the wrong tier (#4249).

`RecoverMissingPullRequestLabelsJob` is not a fit for this: it only adds
labels missing from a *newly created* PR within a 24-hour window, and never
removes a label the PR should no longer carry.

## Design

`Issues::SyncPriorityLabelsToPullRequest` reconciles one issue's linked pull
request to the issue's current priority labels, mirroring the same set
difference used at creation time:

- **Desired** = `project.priority_label_names & issue.labels`
- **Current** = `project.priority_label_names & pull_request.labels` (the
  locally synced PR row — the same source of truth `RecoverMissingPullRequestLabelsJob`
  trusts)
- Adds `desired - current`, removes `current - desired`. Only names in
  `project.priority_label_names` are ever touched — non-priority labels
  (human-added or otherwise) are untouched, add-only accumulation is avoided
  on downgrade.

**Trigger**: `Issues::UpsertFromGithub.call` compares the issue's priority
labels before/after every upsert (`previous_labels & priority_names` vs
`new_labels & priority_names`). Only on an actual change does it look up
`issue.associated_paid_pull_request` and invoke the sync — this keeps a bulk
`FetchIssuesActivity` sync from adding a per-issue query for every issue whose
priority label didn't change. Pull-request records (`issue.is_pull_request?`)
are excluded; only a plain issue's priority labels drive this flow.

**Scope**: open, Paid-created pull requests only — `associated_paid_pull_request`
already resolves this via the producing `create_pr` agent run and filters to
`github_state: "open"`.

**Gating**: `project.inherit_priority_labels?` already folds in the
upstream-mode check (`upstream_feature_enabled?(:pr_labeling)`), so a single
guard covers both "feature disabled" and "PRs target the upstream repo"
(`UPSTREAM-GATE-002`) — the same guard `inherited_priority_labels` uses at
creation time, keeping the two paths symmetric.

**Failure handling**: a `GithubClient::Error` during reconciliation is
logged and swallowed inline, not raised — this runs inside the
`FetchIssuesActivity` sync path and a transient GitHub failure here must not
fail the whole issue sync. Because `UpsertFromGithub` persists the issue's
new labels *before* reconciling, a later sync of the unchanged issue sees no
priority diff and never re-triggers the flow, and
`RecoverMissingPullRequestLabelsJob` only covers newly created PRs within 24
hours — so the inline rescue also enqueues
`Issues::SyncPriorityLabelsToPullRequestJob`, a bounded GoodJob retry
(`retry_on` with polynomial backoff) that re-runs the same idempotent
reconciliation (same guards, same label diff — it no-ops once repaired)
until it applies or the retry policy is exhausted.

## Interplay with PR Label Recovery

`RecoverMissingPullRequestLabelsJob#missing_labels` still re-adds the
*current* issue priority labels to a PR missing them (e.g. after a transient
failure on initial creation) — that stays correct. It does not gain a removal
path; this sync is the only place that removes a stale priority label.

## Code

- `app/services/issues/sync_priority_labels_to_pull_request.rb`
- `app/jobs/issues/sync_priority_labels_to_pull_request_job.rb` (bounded retry)
- `app/services/issues/upsert_from_github.rb` (trigger)

Test: `spec/services/issues/sync_priority_labels_to_pull_request_spec.rb`,
`spec/jobs/issues/sync_priority_labels_to_pull_request_job_spec.rb`,
`spec/services/issues/upsert_from_github_spec.rb`

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Human-applied PR priority label override | Issue labels always win; no override detection | Track "last Paid-applied label" to let a human relabel the PR and have it stick | No existing data captures which priority label was Paid-applied vs human-applied on the PR; adding that tracking is speculative scope beyond the reported failure mode (stale label never updates). Revisit if a human override need is reported. |
| Where to hook the reconciliation | `Issues::UpsertFromGithub.call`, gated on an actual priority-label diff | A separate follow-up job polling all open PRs on a cron, like `RecoverMissingPullRequestLabelsJob` | The issue's priority labels change at the point of a GitHub sync; hooking there reacts immediately and avoids an unbounded polling window. A diff guard before the PR lookup keeps bulk syncs from adding an unconditional per-issue query. |

## Open Questions & Future Decisions

### Deferred

1. Whether a human who manually overrides the PR's priority label should
   have that override preserved against a later issue re-triage. Not
   implemented — see Decisions table.
