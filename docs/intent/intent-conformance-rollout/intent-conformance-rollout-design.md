---
parent: PAID
prefix: INTENT-CONFORMANCE-ROLLOUT
---

# Low-Level Design: Intent-Conformance Measured Rollout

> Implements RDR-067 issue #3870. This is the evaluation boundary for the
> approval-gated operating mode; it does not alter the reviewer’s semantic
> decision or authorize a merge.

## Purpose

The independent reviewer can be structurally correct yet operationally harmful
if it frequently stops conforming work or misses material changes. Before a
project enables either merge guard, Paid runs the reviewer in a separate,
read-only shadow mode and compares verdicts with blinded human adjudication.

## Rollout boundary

`intent_conformance_shadow_review` is the only flag enabled during shadow
evaluation. It schedules and runs the reviewer, persisting its normal,
head-and-revision-bound verdicts. It does **not** enable
`intent_conformance_enforcement`, `approved_intent_amendments`, the scanner
blocker, the Inbox lane, the amendment flow, or `VerifyAtMerge`. Therefore a
shadow verdict cannot affect merge eligibility.

No feature implementation issue may be released into the approval-gated mode
until both the scanner enforcement and final merge guard are active. The
enforcement transition is atomic at the operator level: disable the shadow
flag, enable `intent_conformance_enforcement` and
`approved_intent_amendments` for the same named project, then confirm a new
PR receives both a schedule and a merge-time check.

## Representative corpus and adjudication

The frozen corpus contains at least ten cases in each stratum, pinned to a
repository, base SHA, head SHA, approved design revision, and model/prompt
version:

| Stratum | Expected adjudication | Required shape |
|---|---|---|
| Accepted | `within_scope` | Implements an approved acceptance criterion while varying non-binding internals. |
| Intentionally drifted | `material_drift` | Changes an approved behavior, constraint, scope boundary, or acceptance criterion. |
| Uncertain | `uncertain` | Has incomplete, contradictory, or insufficient design/diff evidence; it must not be counted as accepted. |

Two project operators adjudicate each case independently while blind to the
reviewer output. They record the expected outcome, cited design claim, and
reason. A disagreement is resolved by a third operator and retained with the
case. The corpus manifest contains references and hashes only; repository
patches and prompt bodies remain in the repository/provider and are never
copied into telemetry.

## Telemetry and promotion criteria

For every shadow review retain the existing verdict identity/evidence,
review-schedule timestamps, reviewer model, and reviewer `AgentRun` cost when
available. For every human resolution retain its timestamp and action. The
rollout worksheet reports:

| Measure | Calculation |
|---|---|
| False alarms | Adjudicated `within_scope` cases returned as `material_drift` or `uncertain` ÷ adjudicated accepted cases. |
| Missed material drift | Adjudicated `material_drift` cases returned as `within_scope` ÷ adjudicated drift cases. |
| Escaped changes | Post-merge material drift found by a follow-up issue or amendment after a `within_scope` verdict, ÷ merged `within_scope` PRs. |
| Review cost | Reviewer token/API plus linked reviewer-run infrastructure cost per verdict. |
| Human time | Verdict evaluation to human resolution, reported separately from active adjudication time. |
| Rework | PRs with a `fix_pr` decision or a second reviewed head ÷ reviewed PRs. |
| Delivery time | PR creation to merged/closed timestamp, compared with a same-project pre-shadow baseline. |

Baseline is the prior 30 comparable feature PRs for the named project,
stratified by changed-file band. Promotion requires at least 30 adjudicated
cases (including ten in every stratum), zero missed intentionally drifted
cases, false-alarm rate at or below 10%, no increase in escaped-change rate,
and median delivery time no worse than 20% above baseline. Review cost and
human time have no hidden pass condition: their observed medians, ranges, and
budget exceptions must be explicitly accepted by the project operator.

## Operator rollout and rollback

The project operator publishes the corpus manifest, aggregate worksheet, and
flag snapshot in the project’s rollout record. If any promotion criterion is
missed, the project remains shadow-only and documents the corrective action.
After enforcement, operators review the same aggregate weekly for the first
30 production PRs.

To roll back, disable `intent_conformance_enforcement` and
`approved_intent_amendments`, stop releasing new feature work into the mode,
and hold outstanding candidates until the guard is restored or a human moves
them to another policy. Disabling the reviewer is never treated as a passing
verdict. `intent_conformance_shadow_review` may remain enabled for diagnosis.
