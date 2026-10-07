---
parent: PAID
prefix: EAGER-QUEUE
---

# Low-Level Design: Eager Queue Seeding

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how eligible issues become queued automatic runs (RDR-032)
> and the dequeue-time recheck that keeps the eagerly-seeded queue honest.
> The sibling `auto-pick-queue` segment covers the toggle lifecycle (enable /
> disable → cancel queued runs).

## Purpose

The dashboard queue preview was empty even when many issues were ready,
because auto-pick seeded conservatively — at most one run per project per
tick, gated by a PR-attention limit. Eager seeding flips that: create a
queued `AgentRun` for every eligible issue the moment it becomes eligible,
and let the scheduler decide what to *start*. This makes the queue preview
reflect the real backlog and makes `max_concurrent_runs` the single capacity
gate.

## Seeding services

- **`Issues::EnqueueEligible`** — the single-issue seeding path. It re-checks
  the issue against `DefaultCandidateSource.eligible_scope`, resolves the
  intended agent type, and `find_or_create_by!`s a queued automatic run
  against the unique-active-run index (`idx_agent_runs_unique_active_issue`),
  rescuing `RecordNotUnique` to return the existing run on a race. It still
  respects the canonical `auto_pick_enabled` switch and
  `Issues::AutoPickProjectGate` at call time so stale sync/retry work cannot
  recreate queued runs after the operator turns the feature off.
- **`Issues::BulkEnqueueEligible`** — iterates the eligible scope in batches
  (`find_each`) and delegates to `EnqueueEligible` per issue. No bulk SQL
  upsert; correctness and auditability over throughput.

## Seeding triggers (reactive, not tick-based)

Seeding happens on issue-lifecycle events, not on a cron tick:

| Event | Path |
|---|---|
| Issue synced from GitHub (incremental) | `FetchIssuesActivity#seed_eligible_issues` → `EnqueueEligible` per issue |
| Full issue sync / project import | `FetchIssuesActivity` → `BulkEnqueueEligible`; `Project` import + `AutoPickQueueBackfillJob` |
| `auto_pick_enabled` toggled on | `Project#seed_eligible_issues` (`after_update_commit`) → `BulkEnqueueEligible` |
| Blocking issue closed | `Issue#enqueue_newly_unblocked_dependents` → `EnqueueEligible` per dependent |
| Periodic eligibility sweep | `AutoPickEligibilitySweepJob` → `BulkEnqueueEligible` |

The old one-run-per-project-per-tick `seed_auto_pick_queue` and the
PR-attention seeding limit (`max_auto_pick_open_prs` /
`deferred_by_pr_attention_limit?`) were removed: `max_concurrent_runs` is
the single concurrency control, and `AgentRun::QUEUE_ORDER` (with its
project/user fair-stride keys) decides dispatch order.

## Dequeue-time eligibility recheck

An issue can lose eligibility between seeding and the scheduler claiming the
run — a skip label added, a new blocking dependency, the issue closed, or the
scheduler paused. Paid's internal workflow state is not an eligibility guard.
`AgentRuns::RecheckIssueEligibility` re-checks only eagerly-seeded auto-pick
runs tied to an issue (manual runs, no-issue runs, and `review` goals are
excluded) at dequeue time via `DefaultCandidateSource.eligible_for_dequeue?`.
If the issue is no longer eligible it cancels the still-queued,
unclaimed run under a row lock (so a run claimed mid-check is not marked
cancelled), and the re-enqueue hooks re-seed it when it becomes eligible
again. `ProcessRunQueueJob` runs this recheck before capacity/Docker work so
ineligible runs do not consume expensive admission.

## Failed-run re-enqueue backoff

When a run finishes in `failed` state, the issue re-enters the queue via
`Issue#enqueue_self_if_became_auto_pick_eligible` →
`Issues::ReenqueueEligibleJob`. The wait uses Sidekiq's exponential backoff
curve (`Issue#auto_pick_reenqueue_delay`), with the retry attempt `n` taken
as the consecutive auto-pick failure count minus one (floored at zero):

```ruby
delay = (n**4) + 15 + (rand(10) * (n + 1))
```

First retries are nearly free (sub-minute), the curve keeps growing past the
old 4-hour ceiling, and `consecutive_auto_pick_failure_count` is bounded at
50 so the maximum delay saturates around ~72 days. State transitions that
are not `failed` (e.g. `analyzed → new`) re-enqueue immediately with no
delay.

## Duplicate-PR prevention (#3432, #4039)

`DefaultCandidateSource.eligible_scope` excludes an issue whose `create_pr`
run already recorded `pull_request_number`, unless the local, synced PR
`Issue` row proves that PR closed without merging. The recorded number —
not the run's terminal status — is the produced-PR evidence: a run whose
`complete!` fails after publishing (e.g. a completion-verification gate
raise) is marked `failed` by the workflow failure path while its PR lives
on, and must still block a re-pick that only the publication guard would
reject. This covers two related situations:

- **Synced open PR** — `Issue.open_pull_request_parent_issue_ids` already
  excludes issues with a synced, open, `parent_issue_id`-linked PR row.
- **Unsynced or not-yet-linked PR** — `pull_request_number` is persisted at
  publication, before terminal status
  (`CreatePullRequestActivity#reserve_pull_request!`), and every terminal
  transition stamps `completed_at`, but the local PR `Issue` row (and its
  `parent_issue_id` linkage) is written later by GitHub sync.
  `unsynced_pr_produced_issue_ids` closes that gap by excluding the issue
  directly from `AgentRun` state (completed, failed, or cancelled alike),
  bounded by `PR_SYNC_GRACE_PERIOD` (1 hour) so a PR row that never syncs —
  deleted branch, stale/wrong recorded PR number, sync backlog — does not
  strand the issue forever. This exclusion applies inside `base_scope`, so
  it protects every `paid_state` branch of `eligible_scope`, not only the
  `paid_state: "completed"` recovery branch — closing a race where
  `StaleRunDetectorJob#recover_orphaned_in_progress_issues` (or any other
  path) resets `paid_state` back to a pre-completion value after a PR was
  already opened.

A synced, closed-unmerged PR row always lifts the exclusion immediately
(no need to wait out the grace window), so legitimate replacement runs after
an abandoned or rejected PR are not delayed.

The originating run is also durable evidence when it agrees with a synced
PR row in the same project, whatever terminal status it reached: an open or
merged PR whose `github_number` matches that run's `pull_request_number`
blocks the run's source issue even if `parent_issue_id` was missing during a
prior sync. PR sync reconciles a missing link from this evidence only when
all matching runs resolve to one source issue; conflicting histories are
logged and left unchanged. A PR-scoped follow-up resolves through its
existing parent rather than linking the PR to itself. Closed-unmerged PRs
deliberately do not block recovery.

The originating-run exclusion requires both a source issue ID and a recorded
PR number. Runs without a source issue cannot block other issues; exclusion
subqueries must never return null issue IDs.

Before publishing, `CreatePullRequestActivity` locks the source issue and
checks this same durable open-PR association. It records the returned PR URL
and number on the originating run before releasing that lock, even though
terminal completion occurs later. A second branch reconciles this reservation
against GitHub and cannot turn the existing implementation PR into a
successful result: the duplicate activity stops non-retryably with the
existing PR identified in its reason.

## Code-scanning verification lifecycle (#4053)

Synthetic code-scanning issues (`Issue::SYNTHETIC_CODE_SCANNING_SOURCE`,
seeded by `SecurityAlerts::ProcessCodeScanningAlerts` from CodeQL alerts) walk
the same duplicate-PR-prevention guards above, with one deliberate exception:
a merged remediation PR does not permanently block the issue the way it does
for an ordinary GitHub issue. A merge is not proof the underlying alert is
fixed — the agent's patch might not actually close the CodeQL finding, or a
regression could reintroduce it. Only the scanner itself, on its next pass
over the live alert list, can say whether the alert is actually gone.

`Issue#last_scanner_reconciled_at` records when
`SecurityAlerts::ProcessCodeScanningAlerts` last reconciled a given alert
against the live scan results. Every pass over an alert still reported open
stamps this timestamp, whether or not the issue's title/body/labels changed
— a rescan that finds nothing new is still evidence the scanner looked.
`DefaultCandidateSource#merged_block_issue_ids` compares this timestamp
against the most recent merged remediation PR's observed time
(`Issue#updated_at` on the merged PR row, via either evidence path from
EAGER-QUEUE-009):

- **Not yet reconciled** (`last_scanner_reconciled_at` is `nil` or older than
  the merge) — the issue stays blocked, exactly like an ordinary issue,
  giving the next scheduled scan time to run before any re-pick is possible.
- **Reconciled since the merge** — the block lifts. If the scanner no longer
  reports the alert, `SecurityAlerts::ReconcileResolved` has already closed
  the issue (`github_state: "closed"`) via the ordinary GitHub-open-authority
  gate, so lifting this guard is moot. If the scanner still reports the
  alert open, the issue is genuinely recurrent and becomes eligible for a
  fresh remediation attempt.

Ordinary GitHub issues are unaffected: `merged_block_issue_ids` only relaxes
the exclusion for `SYNTHETIC_CODE_SCANNING_SOURCE` issues, so a merged
implementation PR keeps blocking a regular issue forever, as before.

### Post-merge analysis evidence (#4147)

`SecurityAlerts::VerifyMergedRemediationAttempts` verifies a recorded attempt
against `GET /repos/{owner}/{repo}/code-scanning/analyses`. That endpoint does
not return a `status` field: per GitHub's documented schema each analysis
carries required `error` and `warning` strings plus identity fields (`id`,
`ref`, `commit_sha`, `category`, `tool.name`), and is listed newest-first.
`GithubClient#code_scanning_analyses` therefore normalizes each documented
response into one of four evidence states — success is never inferred from
HTTP 200 or from `results_count`:

- **succeeded** — `error` is present as an empty string and the identity
  fields needed as evidence (`id`, `ref`, `commit_sha`) are complete.
- **failed** — `error` carries the analysis failure text (retained verbatim).
- **malformed** — the response omits documented required fields (e.g. no
  `error` key, missing branch/commit identity, or missing `tool.name` /
  `category`), so success cannot be affirmed and configuration matching
  cannot be trusted; the attempt stays blocked.
- **unavailable** — no analyses exist for the repository at all.

`VerifyMergedRemediationAttempts` selects evidence from analyses that match
the finding's tool/category *and* live on the target branch, iterating
newest-first over matching successful entries until one is found whose commit
contains the merge — so a newer PR-branch, unrelated-configuration, or stale
rerun analysis can never hide valid evidence, and an error-bearing newer
analysis falls through to older successful evidence when it exists. Iterating
matters specifically because a newer entry can be a rerun of an older main
SHA after a valid post-merge analysis has already been uploaded: taking the
newest entry alone would yield `behind` on the compare, blocking the attempt
on `verification_blocked` while `awaiting_attempts` skips that status, so the
legitimate later analysis would never be reconsidered. When no matching
successful analysis contains the merge, the closest related analysis is
retained as blocked-attempt evidence (relevant analysis first, then any
configuration match, then the newest analysis). Blocked evidence records the
analysis `error`/`warning` text alongside branch/commit/configuration
identity. Resolution (`verified_fixed`) is only ever derived from that
structural evidence plus the alert no longer being reported open — never from
the merge itself or from aggregate result counts.

## Idempotent PR/issue link repair (#4052)

`Issues::ReconcilePullRequestSource.candidate_source_issues` exposes the same
evidence-matching `sources` lookup `#call` uses, without writing, so the
`issues:repair_pull_request_source_links` rake task can report and backfill
missing `parent_issue_id` links for PRs that synced before their originating
run's evidence was reconciled (e.g. a PR that stayed open past
`PR_SYNC_GRACE_PERIOD` before its local row existed). The task is safe to
re-run: it only ever links a PR with exactly one candidate source issue,
logs (and skips) any PR with conflicting candidates rather than guessing,
and — because a repaired link can retroactively prove a queued run is a
duplicate — routes any such run through the normal
`AgentRuns::RecheckIssueEligibility` cancellation path instead of leaving it
runnable.

## Fair-stride impact

None. `QUEUE_ORDER` already sorts by project and user in-flight counts ahead
of queue priority, so eager seeding adds queued rows per project without
changing which runs the scheduler starts. A project with many queued issues
still only gets its fair share of concurrent slots; the dashboard preview
simply shows the full backlog.

## What this is not

- **Not a capacity control.** Eager seeding creates runs; it does not start
  them. `max_concurrent_runs` + `Capacity::RunAdmission` decide what runs.
- **Not strict-priority ordering.** See `queue-priority-tiers` and
  `account-queue-fairness` for how queued runs are ordered and whether an
  account opts out of fair-share.
- **Not focus scoping.** See `focused-agent-runs`; eager seeding is
  orthogonal to what problem a run targets.
