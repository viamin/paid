---
parent: PAID
prefix: AUTO-MERGE
---

# Low-Level Design: Auto-Merge Strategy

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment records the shipped auto-merge policy after RDR-022 closed the large
> umbrella branch in favor of incremental delivery.

## Purpose

Paid lets project owners delegate the final merge decision under a narrow,
revocable policy instead of requiring a manual click for every pull request.
The current implementation splits that policy into:

- strategy evaluation for human-authored and bot-authored PRs
- a Dependabot-specific execution path for dependency updates
- project configuration that keeps auto-merge owner-controlled

An agent applies `paid-hold-review` only when a pull request it creates or
materially changes has a concrete human-only decision that ordinary delegated
checks cannot settle. Examples include an explicit design or intent approval
gate, a material scope or authority change, or another decision the project's
automation is not authorized to make. A user-facing change, a request for a
screenshot or review, normal CI or bot review, missing verification evidence,
or general caution is not such a decision; those follow their ordinary
verification or blocker path. An agent does not hold an existing pull request
merely because it encounters it while completing dependency or bookkeeping
work, unless its assigned task explicitly requires that review or hold.

This is a structured, per-PR hold — never an interpretation of prose — and it
blocks both scan-time eligibility and the last-mile merge activity. When it is
used, the agent records the unresolved decision, why delegated checks cannot
settle it, and the pull-request, run, and issue evidence in a durable
operator-visible update; the label remains the merge blocker. Held PRs appear
in the Inbox's merge-approval lane with a human-review summary, even if
ordinary approval/check signals have not yet been evaluated. A human releases
the hold by removing the label.

Technical merge blockers are Paid state on the pull request, independent of
GitHub labels and label integration mode. Each bounded entry identifies a stable
key, the observed PR head, reason, responsible project issue and release
condition. Confirmed writes require project issue-management authorization.
Resolution records evidence and matches the exact entry version, preventing a
stale request from erasing a newer stop. Both actions are audited; semantic
judgment belongs to the authorized operator or delegated agent. Neither action
grants merge approval or bypasses the normal checks.

Unresolved technical blockers prevent scan-time auto-merge and every final
merge execution, including dependency-update and credential-fallback paths.
Final executors reload the internal state before merge I/O. A push, clean
review, policy change or green CI does not implicitly resolve a separate stop.
PR diagnostics expose technical work with its owner and release condition;
that state does not create a human-approval Inbox item. Agents use this path for
technical acceptance/integration stops instead of `paid-hold-review`. Existing
labels are never automatically reclassified from prose. Converting a verified
technical hold requires enforcing its internal replacement before label removal.

This segment captures the shipped behavior rather than the abandoned umbrella
PR strategy discussed in RDR-022.

## Shipped behavior

The core strategy is policy-only. Upstream scan layers gather signals about
approvals, CI, mergeability, stale reviews, review feedback, and dependency
resolution, then `Automation::Strategies::AutoMerge` converts those signals
into either a merge decision or a blocker snapshot that records exactly which
signals failed and which later checks were not evaluated because an earlier
gate already failed.

Auto-merge diagnostics read from that persisted snapshot instead of
re-evaluating eligibility a second time. The PR scan writes the snapshot onto
the synced issue row alongside `last_pr_scan_at`, so UI and chat surfaces can
report the same blockers the merge path used without making fresh GitHub API
calls or re-implementing the policy.

Human-authored PRs take the stricter path. They require owner approval,
successful checks, mergeability, fresh reviews for the current head, no
outstanding blocking review feedback, and resolved dependencies before a merge
decision is emitted. A blocking approval is treated as fresh when every commit
on the first-parent path from HEAD back to the approved commit is a clean
merge of the PR's base branch into the feature branch — i.e. a merge commit
whose second-parent side is reachable from the base branch tip and whose tree
is identical to its first-parent tree. This prevents `chore: merge origin/main`
refreshes (including those produced by Paid's own `auto_fix_merge_conflicts`
path) from dropping a PR out of auto-merge eligibility when they introduce
no author-side content. The first-parent path (rather than the full compare
response) is used because GitHub's compare endpoint is equivalent to
`git log BASE..HEAD` and also returns the base-branch commits that arrived
only through the merge's second parent; those single-parent commits are
content-free by transitivity once the merge's second parent is reachable
from the base branch tip, so the walk ignores them. Any commit that cannot
be positively classified as content-free continues to invalidate the
approval (fail closed), as does a post-approval range the first-parent walk
cannot fully return (the walk is bounded at the same 250-commit cap GitHub
imposes on its compare response; an over-cap walk is unclassifiable), and
the classification decision is logged so a stall is diagnosable.

The dependency gate evaluates qualified cross-project declarations through an
exact case-normalized project tracked in the same account and that project's
configured provider identity. A closed issue or merged pull request satisfies
the declaration only after that current provider read. An untracked,
inaccessible, open, closed-unmerged, or transiently unverifiable source remains
blocked; Paid-local completion state, sibling relationships, and agent
inference do not create dependency evidence. The existing unresolved-dependency
blocker directs operators to the declared dependency source without introducing
a separate dependency UI.

When an automatic rebase finds conflicts, the resulting existing-PR run is a
repair, not a continuation of general implementation work. Its trusted prompt
limits it to integrating the base branch and resolving the necessary conflicts
within the PR's existing task and approved intent; a needed change outside that
scope is reported for human direction. Before accepting the repair, Paid uses
the agent harness to assess the bounded diff evidence and fails closed when the
assessment is unavailable, malformed, or identifies out-of-scope author work.
It persists separate base-import and repair-authored paths so the normal update
comment can make that distinction legible to reviewers. A repair does not carry
an approval across substantive conflict-resolution content and does not change the separate auto-merge policy:
the existing fail-closed first-parent freshness classifier remains the sole
authority for whether current-head review is required.

The completion envelope around that assessment is bounded (#5310): the
existing-PR completion activity derives one finite deadline from its Temporal
start-to-close budget, bounds the initial PR metadata read and the comparison reads that gather assessment
evidence by that same envelope, deducts their elapsed time before admitting
the harness assessment request, and gives that request only what remains
after a deliberate publication reserve. It reuses the already-persisted
assessment — bound to the exact pre-run, integration-base, and pushed head
SHAs — on any activity retry rather than spending another request. The
assessment plus its durable persistence always precede PR publication. If initial
metadata is unavailable or its read budget is exhausted, completion records an
unavailable assessment bound to the recorded pre-run and pushed SHAs, leaves the
unknown integration base unset, skips publication, and raises the same typed
stop without requesting semantic assessment. A
malformed, unavailable, or rejected decision persists the exact pushed commit
and bound scope status and then raises the typed non-retryable
`ConflictRepairScopeRejected` review stop. Publication on that stop path runs
only inside the remaining reserve, deduplicates its comment per repair range,
and is abandoned with a sanitized warning when the reserve is exhausted, so a
slow or unavailable GitHub publication can neither consume the activity's
remaining attempts nor replace the actionable typed classification with a
generic timeout. The activity records sanitized per-component elapsed
diagnostics on its phase record (assessment and publication timings, bound
scope status, and whether rejection publication was abandoned) without
persisting prompts or raw provider output.

The assessment input itself is complete-or-explicit, never silently partial
(#5312). The prompt carries the complete immutable result-path inventory —
every path changed in the pre-run-to-result range is listed — and the evidence
formatter may no longer drop paths invisibly when joined patch text exceeds the
prompt bound. Git blob SHAs from the compare API mechanically separate the two
sides of the evidence: a result path whose blob SHA equals the base-import
range's blob SHA for the same path is a verified base import (byte-identical
content, no repair-authored delta) and needs no diff text in the prompt, which
is what keeps the normal large-base-import/small-repair case inside the
existing bounded context, time, and spend. Every unverified path receives
bounded diff evidence: a complete or truthfully marked patch excerpt, or an
explicit no-patch note for binary and API-omitted diffs. When the complete
inventory or the per-path evidence cannot be held within the established
bounds, or when path metadata contains control characters that could forge
inventory lines, the assessment fails closed before the harness call with an
explicit input-coverage reason rather than sending hidden or truncated
evidence. Output validation stays strict and mechanical: every actual result
path must be accounted for, a path outside the base-import range cannot be
claimed as a base import, a blob-verified import cannot be classified as
repair-authored, and malformed or path-incomplete results classify as
unavailable. Semantic scope judgments — whether an authored edit belongs to
the PR task — remain with `agent_harness`; Ruby only verifies structure and
blob identity. The pre-existing file-count truncation guard (>= 300 compare
files) is preserved unchanged.

Bot-authored dependency PRs take the narrower trusted path. Dependabot-like PRs
may skip owner-approval and review-feedback gates, but they still require the
project to permit dependency auto-merge, a supported executor author, green
checks, mergeability, and resolved dependencies. Today the merge executor is
Dependabot-specific, so other trusted dependency-update bots may be scanned and
diagnosed but are not reported as auto-merge-ready.

Execution is incremental rather than umbrella-driven. The dedicated
`DependabotAutoMergeJob` evaluates candidate PRs, merges at most one green PR
per pass, labels/comment-tags successful merges, and treats expected merge
rejections as logged no-ops rather than crashes. App-backed projects that have
a PAT push fallback configured reuse that fallback when a Dependabot merge is
rejected for a missing workflow permission. Terminal workflow-permission
failures reuse the PR row's merge-permission cooldown so Paid does not retry
the same permanent failure every poll cycle.

Auto-merge diagnostics are persisted as sanitized product data. Each merge
path appends an `AutoMergeAttempt` row for meaningful outcomes (merge, skip,
blocker, failure) so the UI, support workflows, and chat agents can explain
what happened without raw logs, tokens, webhook secrets, or stack traces.
Attempt rows are tenant-scoped through PostgreSQL row-level security keyed on
`projects.account_id`, so access follows project visibility.

GitHub's own mergeable/review state does not reflect Paid's stricter
freshness gate: an approval GitHub still counts as valid can be stale by
Paid's first-parent-walk policy above, so a PR the owner would consider done
sits green in Paid's dashboard while GitHub shows nothing for the owner to
do — the approving review is still on record there. When the persisted
auto-merge blocker snapshot reduces to exactly that stale-approval signal
(every other precondition green), the scan re-requests GitHub review from
the project's `owner_reviewer_login`, which puts the PR back in the owner's
native "Awaiting your review" queue. The request is guarded to at most one
per PR HEAD commit SHA: the workflow stamps `issues.owner_review_requested_sha`
only after GitHub accepted the request or confirmed it was already pending,
and the scan skips re-requesting until a new commit changes that sha.
A handled no-op or transient GitHub failure does not stamp the guard, so the
next poll can retry. A PR blocked by anything else (red CI, unresolved
threads, incomplete blocking reviews) is waiting on the agent, not the owner,
and never generates a request.

## What this is not

- **Not a blanket bypass of human control.** Projects must opt in through
  `auto_merge_mode`; `off` remains the default.
- **Not a rebase of PR #950.** RDR-022's decision was to preserve the shipped
  behavior via focused incremental changes, not to revive the stale umbrella
  branch.
- **Not a trust grant for arbitrary bots.** The simplified path is limited to
  dependency-update bots the project explicitly supports.
- **Not PR-body parsing.** A request for review in prose does not change merge
  authority; the explicit hold label is the only agent-controlled review gate.
  Nor is prose a substitute for the required structured label when an explicit
  human-only decision remains unresolved.
