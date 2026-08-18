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
`merge_conflict`, `conversation`, `issue_implementation`, `label_action`.
`general` is the unscoped default and reproduces the legacy all-in-one
behavior; manual/quick runs keep it. The column is non-null with a
`"general"` default, so every run — old or new — resolves to a focus.

## Focus resolution

The PR scanner resolves focus from the triggers it collected, not from a new
operator input. `ScanPaidPrsActivity::TRIGGER_TO_FOCUS` maps each trigger
type to a focus, and `FOCUS_PRIORITY` selects the single highest-priority
focus present:

```
merge_conflict > ci_fix > review_feedback > conversation > issue_implementation > label_action
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

## Focus-scoped quality scoring

Quality weights are selected per focus (`QualityMetric::FOCUS_WEIGHTS`,
`QualityMetric.weights_for(focus:)`) instead of the single composite
`SCORE_WEIGHTS` table. A `ci_fix` run is weighted mostly on `ci_passed`; a
`review_feedback` run is weighted mostly on `focus_resolved`. `general` runs
keep the composite weights, so their scores are unchanged.

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
| `issue_implementation` | linked-issue requirements met |
| `label_action` | actionable labels cleared |

The composite score is recomputed with the focus-specific weights once the
`focus_resolved` value lands. Attribution runs only for the focuses in
`FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES` (i.e. not `general`).

## PR automation fuses

Focused runs still need a hard spend fuse because a repeated PR follow-up can
fail before resolving its focus. Each project has a
`max_pr_auto_continue_tokens` cap for automatic runs tied to a single pull
request. Before the poll workflow queues another automatic create-pr or review
run for a PR, `CheckQualityGateActivity` sums recorded tokens from prior
automatic runs on that PR. If usage has reached the cap, the workflow skips the
new run and escalates the PR instead.

Escalation also pauses `auto_continue_paused` for the PR. Dismissing escalation
resumes it, preserving the existing "remove the escalation label to let
automation try again" operator flow.

## What this is not

- **Not parallel runs per PR.** Runs are sequential — one focused run per
  scan cycle; the next poll schedules the next focus. Parallel runs on the
  same branch would conflict.
- **Not a new `goal`.** Focus is orthogonal to execution mode; it does not
  change container/review/issue-creation flows.
- **Not per-project configurable weights.** Focus weight maps are
  hard-coded today; per-account tuning is deferred until validated.
