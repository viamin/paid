---
parent: PAID
prefix: INTENT-MERGE-GUARD
---

# Low-Level Design: Approved Intent Final-Merge Guard

> Companion to the high-level design (`docs/high-level-design.md`). Implements
> the final-merge precondition slice of
> [RDR-067](../../rdrs/RDR-067-approved-intent-conformance.md) (#3868):
> re-verifying the current PR head, the approved design revision, and the
> intent-conformance verdict immediately before merge, so a push or design
> amendment between scan and merge cannot bypass the gate.

## Purpose

`Automation::Strategies::AutoMerge` decides eligibility from a scan-time
`Signals` snapshot; the decision it produces can sit in a workflow queue
before `Activities::MergePullRequestActivity` actually executes the merge.
RDR-067 requires that the final merge activity re-check PR head, approved
design revision, and verdict identity against *current* data at that moment —
not the cached scan-time snapshot — so neither a new push nor a design
amendment landing in the gap can slip an out-of-date verdict through. No
fallback interprets a missing verdict as approval (fail closed).

## Scope

In scope (this segment):

- `IntentConformanceVerdict` — the minimal structural verdict identity record
  the guard reads: which PR head and approved design revision the outcome
  (`within_scope` / `material_drift` / `uncertain` / `not_evaluated`) was
  evaluated against, and when. Reviewer evidence (cited claims, reasoning,
  run/model metadata) belongs to the independent reviewer run (#3866); this
  record carries only the identity/outcome fields the final-merge guard (and
  the PR-scanner blocker, #3867) need to check. Both sibling issues extend
  this table rather than duplicating it.
- `IntentConformance::VerifyAtMerge` — the final-merge precondition, called
  directly from `Activities::MergePullRequestActivity#execute` immediately
  before requesting merge (not from the cached `AutoMerge::Signals` snapshot),
  so it always evaluates current data.
- Wiring into `MergePullRequestActivity`: a new blocked branch, parallel to
  the existing skip-label and merge-permission-cooldown branches, that
  records an `AutoMergeAttempt` with `reason_code:
  intent_conformance_blocked` and returns without merging.

Out of scope (owned by sibling issues under #3861): the independent
conformance reviewer run that writes verdicts (#3866), PR-scanner blockers
and Inbox escalation of drift verdicts (#3867), design amendment and revision
impact mapping (already delivered — see
`docs/intent/approved-intent-amendment/`), evaluation and rollout telemetry
(#3870).

## Design

### Applicability (rollout guard)

The guard is a no-op unless **both** of the following hold, preserving
"existing projects remain off by default" (RDR-067 §Rollout Guard):

1. The merging issue is linked to a `FeatureIntent` (`issue.feature_intent`,
   via `feature_intent_issues`).
2. The project has opted into the `approved_intent_amendments` feature flag —
   the same RDR-067 mode flag `DesignAmendments::Open` already gates. Per the
   issue's rollout instruction ("keep the named mode disabled for execution
   until scanner and final guard are both active"), enabling this flag for a
   tenant is the operator's signal that both #3867 and this guard are wired;
   this segment does not introduce a second flag.

When either condition is false, `VerifyAtMerge.call` returns `nil` and the
activity proceeds exactly as it did before this change.

### Check order (fail closed)

For an applicable PR, `VerifyAtMerge#call` evaluates, in order:

1. **Feature revising** — `feature_intent.revising?` (a design amendment is
   open) blocks unconditionally. A revision changes the approved baseline the
   PR must conform to; nothing can be current against a moving target.
2. **Active hold** — an active (`held`) `DesignAmendmentPause` on the issue
   blocks unconditionally, regardless of verdict state. Impact evaluation
   already decided this branch needs to pause; the merge guard enforces it at
   the last moment even if the pause was applied after auto-merge already
   scanned the PR as eligible.
3. **Verdict lookup** — the most recently recorded `IntentConformanceVerdict`
   for the issue (`IntentConformanceVerdict.current_for`). Missing → blocked
   (`verdict_missing`). No fallback treats absence as approval.
4. **Verdict identity** — the verdict must match *both* the PR head SHA
   fetched fresh in this activity call and the feature intent's current
   `approved_design_revision`. A mismatch on either axis → blocked
   (`verdict_stale`): a stale head means a push happened after the verdict
   was recorded; a stale revision means a design amendment merged a new
   baseline after the verdict was recorded. This is the scan-to-merge race
   the RDR requires closing — the check re-fetches PR head data in the
   activity itself rather than trusting the value the scan step observed.
5. **Outcome** — `within_scope` on a current verdict allows the PR through to
   the project's other existing merge preconditions (owner approval, checks,
   mergeability, etc. — unchanged). `material_drift`, `uncertain`, and
   `not_evaluated` all block by default.
6. **Human exception** — for a blocking outcome, an `IntentConformanceResolution`
   with `resolution_type: implementation_exception` bound to the *exact*
   current PR head authorizes merge despite the drift/uncertain outcome (the
   bounded one-PR exception from RDR-067 §Human decision and amendment). A
   `require_within_scope` resolution never authorizes merge — it is a
   directive to keep implementing, not an approval. An exception bound to a
   different (older) head does not apply; a new commit invalidates it, same
   as it invalidates a verdict.

### Placement in the merge activity

`Activities::MergePullRequestActivity#execute` already fetches a fresh
`pr_data` (including `head_sha`) from the provider before attempting to
merge, and already has a "not yet merged" branch structure with several
early-exit conditions (`merge_permission_retry_due?`, skip label). The
conformance check is added as one more branch in that same structure,
evaluated with the just-fetched `pr_data.head_sha` — guaranteeing the guard
sees the PR's current head, not a value cached from the scan step. A blocked
result records an `AutoMergeAttempt` (`status: blocked, reason_code:
intent_conformance_blocked`) and returns without calling
`provider.merge_pull_request`, exactly like the other blocking branches.

### Non-goals

- This segment does not run the AI reviewer or write `within_scope` /
  `material_drift` verdicts from PR content — that is #3866. Until #3866
  ships, any project with the rollout flag enabled and a linked feature
  intent will see every merge blocked with `verdict_missing`, which is the
  correct fail-closed behavior for an unwired reviewer, not a defect in this
  guard.
- This segment does not add a PR-scanner blocker or Inbox item — that is
  #3867. The final-merge guard is deliberately independent of the scanner's
  cached blocker snapshot so it cannot inherit scan-time staleness.

## Persistence

- `intent_conformance_verdicts` — verdict identity: project, issue, PR head
  SHA, approved design revision, outcome, recorded-at. No logidze (high write
  volume expected once the reviewer run is wired; operational, not
  configuration data).
