---
parent: PAID
prefix: FOCUSED-RUN
---

# Low-Level Design: Focused Agent Runs

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers single-problem-per-run scoping for PR follow-up work
> (RDR-031). Focus is shipped as default behavior; the rollout feature flag
> described in the original RDR has been removed.

## Purpose

When a PR carries several unrelated problem classes at once (failing CI,
unresolved review threads, merge conflicts, conversation comments), an
all-in-one run spreads the agent's attention across them, produces shallower
fixes, and misattributes quality. Focused runs scope a single agent run to a
single problem class so the agent goes deep on one thing and the quality
score judges it against only that thing.

## The `focus` concept

`focus` is a field on `agent_runs`, **orthogonal** to `goal`. `goal` decides
*how* the agent executes (create code, review code, enhance an issue);
`focus` decides *what PR problem* the agent targets within a run.

Focus values (`AgentRun::FOCUSES`): `general`, `ci_fix`, `review_feedback`,
`merge_conflict`, `conversation`, `performance_regression`,
`issue_implementation`, `label_action`.
`general` is the unscoped default and reproduces the legacy all-in-one
behavior; manual/quick runs keep it. The column is non-null with a
`"general"` default, so every run — old or new — resolves to a focus.

## Focus resolution

The PR scanner resolves focus from the triggers it collected, not from a new
operator input. `ScanPaidPrsActivity::TRIGGER_TO_FOCUS` maps each trigger
type to a focus, and `FOCUS_PRIORITY` selects the single highest-priority
focus present:

```
merge_conflict > ci_fix > review_feedback > conversation > performance_regression > issue_implementation > label_action
```

Triggers that map to no focus (or none present) fall back to `general`. The
resolved focus flows through the workflow into the created agent run.

## Focused prompt scoping

`Prompts::BuildForPr` accepts the run's `focus` and:

- **Includes only the section for that focus** (`include_section?`,
  `scoped_section_for_focus`) — a `ci_fix` run gets the CI section, a
  `review_feedback` run gets the code-review section, etc. `general` and
  `label_action` keep all applicable sections (all-in-one behavior).
- **Collapses the priority list to a single item** (`focused_priority_list`)
  describing only the scoped task.
- **Appends an "Other Issues on This PR (Deferred)" section**
  (`other_issues_section`) listing the other present-but-deferred problem
  classes, with an explicit instruction to ignore the fix-forward directive
  for them so the agent neither regresses nor silently fixes them.

## Review-thread closure evidence

The review-feedback prompt captures trusted unresolved thread identities so a
follow-up can address the feedback, but capture, successful execution, a push,
or a rebase are not proof that any particular finding is repaired. Before the
public GitHub mutation, `AssessFollowupReviewThreadsActivity` obtains a fresh
agent-harness judgment over the captured threads at the current head. Its exact
structured response is mechanically checked for explicit authorization, captured trusted IDs, a
supported disposition, explicit rationale, the observed head SHA, and a digest
of the exact thread content assessed. Complete evidence is paginated only for
captured threads and is bounded by finite request, page, comment, and byte
budgets; missing or cyclic cursors and budget overflow fail closed rather than
authorizing a partial thread. `ResolveReviewThreadsActivity` reads the head and
threads again immediately before its mutation, and requires every authorized
thread digest to remain unchanged. The workflow leaves findings open when
either boundary is unavailable, invalid, stale, or inconclusive. The Temporal
patch guard retains old recorded resolution commands for replay until the
patch-guard sunset sweep authorizes their removal. This preserves valid no-code
dispositions (for example invalid, outdated, or already-fixed feedback) without
hiding feedback appended after assessment or equating unrelated changed lines
or generic agent success with repair evidence.

The PR scanner consumes that public thread state at the next admission
boundary. A body-only-capable reviewer is not assumed to have produced only a
top-level finding: when its latest review has inline comments and none of their
threads remains unresolved, the scanner treats that inline feedback as closed
and does not enqueue the same coding follow-up again. Associated-comment state
is checked before timestamp-based body-only follow-up decisions, including for
a fresh review. A genuine top-level-only
finding remains actionable, as does any review whose comment data cannot be
fetched. Changed files are not closure evidence; partial or unrelated changes
continue to require an open thread or a fresh reviewer disposition.

## Focus-scoped quality scoring

Quality weights are selected per focus (`QualityMetric::FOCUS_WEIGHTS`,
`QualityMetric.weights_for(focus:)`) instead of the single composite
`SCORE_WEIGHTS` table. A `ci_fix` run is weighted mostly on `ci_passed`; a
`review_feedback` run is weighted mostly on `focus_resolved`. `general` runs
keep the composite weights, so their scores are unchanged.

## Conversation feedback consumption

The scanner's conversation-comment cutoff decides which trusted comments are
still "new" enough to admit a follow-up run. Only a `completed` `create_pr`
run whose focus includes the conversation section may contribute its
`completed_at`: a focused run that excluded conversation feedback cannot
acknowledge it. A terminal `no_output`/`no_changes` `create_pr` run is a
valid no-change outcome for the feedback it was shown, but its status hides
it from the completed-run lookup — so the same trusted comment kept
re-admitting follow-ups (#5180).

`check_conversation_comments` therefore considers completed `create_pr` runs
and `create_pr`/`no_output`/`no_changes` runs whose focus includes the
conversation section — `conversation` itself, plus unscoped `general` and
`label_action` (the same rule as `Prompts::BuildForPr#include_section?`).
For recorded prompt preparation, the cutoff is immediately before the start
second of the latest successful preparation, provided it finished before
terminal completion. Provider comments can have whole-second timestamps while
phase clocks retain fractions; same-second ordering is therefore ambiguous.
Retain those comments conservatively rather than claiming they were shown.
Completion time cannot acknowledge a comment that arrived after the prompt
was assembled. A failed or late preparation supplies no acknowledgment;
legacy runs with no preparation record retain a cutoff immediately before
their completion second. A subsequent preparation in a later second consumes
already-shown feedback normally; no run timestamp or allowance is changed.
Take the maximum context cutoff across all eligible run history, rather than
choosing by completion order, so a late-finishing older prompt does not hide
a newer context or cause duplicate follow-ups. This is a scalar indexed
phase lookup in the existing project/PR history query; it neither loads all
phases nor rewrites run timestamps. Other focuses consume nothing. All other cutoff
consumers (review threads, changes requested, review-bot status, CI, policy
and budget gates) keep using completed runs only.

### Explicit operator acceptance reports

An authorized project operator may use `record_operator_acceptance_report` to
record a trusted PR conversation comment as acceptance evidence rather than a
coding request. The recorder fetches the comment and current provider head,
then writes the existing account activity audit event with the project/PR,
authorized actor, comment identity and body digest, exact head revision,
environment, results, and unrun capabilities. It creates no `AgentRun`, does
not alter comment watermarks, counters, budgets, or active owners, and is
idempotent for the same comment body and revision.

The scanner suppresses only an exact current receipt: same PR, comment ID and
body digest, and current head revision. A replay, changed comment, stale head,
untrusted comment, Paid status comment, or later neighboring actionable comment
therefore remains distinct and follows ordinary trusted-comment admission.
Purpose is selected by the explicit authorized operation, never inferred from
keywords or prose. Existing account activity UI/API/MCP audit readers expose
the receipt and its provenance.

## Standalone review-feedback routing

Standalone GitHub review bodies use the same latest-review-per-author and
completed-run cutoff mechanics as `CHANGES_REQUESTED` reviews. A nonblank
trusted `COMMENTED` review body may therefore route one normal
`review_feedback` follow-up even when GitHub cannot create an inline thread.
A clean verdict produced by the configured Paid Agent reviewer carries its
review marker, and a configured review-bot summary matching the shared
clean-review classifier is excluded from standalone findings even though
GitHub represents either as a nonblank `COMMENTED` review. A later clean review supersedes
the earlier body, and reviews observed before the completed-run cutoff are not
requeued. This is prompt context only: it does not manufacture a review-thread
identifier, resolve review state, or renew retry and allowance budgets.

A configured bot's `COMMENTED` review that has associated inline comments is
not an independent standalone finding. It continues through the existing
thread lifecycle, including resolved-inline suppression. The standalone route
requires a known absence of associated inline comments for such bot reviews;
unavailable comment state remains an incomplete review gate, not coding work
or an all-clear result. Human standalone findings retain their existing trust
and cutoff rules.

## `focus_resolved` attribution

A new `focus_resolved` metric (0.0 / 1.0) measures whether the focused
problem was actually resolved. The scanner writes it back to the previous
run's automated `QualityMetric` on the *next* scan cycle by comparing PR
state (`record_focus_resolution` → `focus_resolution_scores`):

| Focus | Resolved (1.0) when |
|---|---|
| `ci_fix` | all CI checks green (deferred while checks still pending) |
| `review_feedback` | no unresolved review threads remain |
| `merge_conflict` | PR is mergeable |
| `conversation` | no actionable conversation trigger remains |
| `performance_regression` | the page load finding the run targeted is resolved |
| `issue_implementation` | linked-issue requirements met |
| `label_action` | actionable labels cleared |

The composite score is recomputed with the focus-specific weights once the
`focus_resolved` value lands. Attribution runs only for the focuses in
`FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES` (i.e. not `general`).

## Verified follow-up thread resolution

Follow-up thread resolution binds its semantic assessment to a complete
immutable comparison file list within the request's file ceiling. The GitHub
client raises a typed unavailable error when the local ceiling or upstream
file-list cap prevents proving completeness, rather than silently dropping
paths. Required per-file path/status, blob identity, nonnegative change counts
and rename provenance are checked before returning evidence; status must match
the provider's [diff-entry schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json).
Absent binary patch text is permitted. The bounded diff keeps every file's
metadata and shares the patch budget among complete or explicitly marked
excerpts. If complete metadata and minimum per-file excerpts cannot fit, the
assessment remains unavailable before calling the model. File omission cannot
authorize resolution. Patch and thread excerpts retain explicit byte-budget markers. Only
thread IDs actually included in the bounded prompt receive content-version
bindings and may be authorized; omitted findings remain actionable.

## PR automation fuses

Focused runs still need a hard spend fuse because a repeated PR follow-up can
fail before resolving its focus. Each project has a
`max_pr_auto_continue_tokens` cap for automatic runs tied to a single pull
request. Before the poll workflow queues another automatic create-pr or review
run for a PR, `CheckQualityGateActivity` sums recorded tokens from prior
automatic runs on that PR. If usage has reached the cap, the workflow skips the
new run and escalates the PR instead.

Escalation hands the PR to the owner. What holds it there, how the owner sees
it, and how it is cleared belong to `pr-escalation-recovery`; this segment ends
at the decision to escalate.

## What this is not

- **Not parallel runs per PR.** Runs are sequential — one focused run per
  scan cycle; the next poll schedules the next focus. Parallel runs on the
  same branch would conflict.
- **Not a new `goal`.** Focus is orthogonal to execution mode; it does not
  change container/review/issue-creation flows.
- **Not per-project configurable weights.** Focus weight maps are
  hard-coded today; per-account tuning is deferred until validated.

## Temporary escalation limit suspension

The project deadline defined by `PR-ESCALATION-028` suspends ready-phase
follow-up count/failure-streak limits and the cumulative automatic PR token
cap. Both scanner and execution admission consult the same deadline.
Expiry restores enforcement against retained usage; per-run execution limits,
draft review limits, review retry limits and operational failure breakers
remain authoritative throughout.
