# RDR-082: Optional Outcome Feedback for Autonomous Assessments

## Metadata

- **Date**: 2026-11-23
- **Status**: Draft
- **Type**: Product workflow and assessment evaluation
- **Owner decision**: Pending review of an exact revision.
- **Related issues**: No replacement issue tree has been filed. Existing work
  must be inventoried before changing its scope or dependencies.
- **Prior RDR impact**: Narrows RDR-067 measured rollout to approval-gated
  operation; complements RDR-070/071 assessment and delivery, RDR-009 tuning,
  and RDR-077/078/080 execution authority. Details below.
- **Intent**: [Outcome feedback design](../intent/outcome-feedback/outcome-feedback-design.md)
  and [proposed requirements](../intent/outcome-feedback/outcome-feedback-specs.md).

## Problem

Paid needs evidence about mistaken implementations and assessments without
requiring users to evaluate a historical corpus before ordinary autonomous
work can proceed. The existing comparison form asks users to reconstruct
approved requirements, inspect diffs, and label cases before comparing their
answers with the reviewer. That effort provides little immediate benefit to
someone trying to use or correct a feature.

Controlled comparison remains useful for evaluating reviewer changes, but it
serves a different purpose from collecting feedback on delivered behavior.
Operational feedback should help resolve a concrete problem and preserve
evidence for improving future assessments.

## Recommendation and serious alternatives

Make optional outcome feedback the primary human evaluation loop for
autonomous operation. Paid continues assessing implementations without
mandatory human comparison. Users can give a feature or acceptance criterion
a quick positive or negative vote; negative votes may include expected and
observed behavior. Paid connects feedback to the implementation and its
recorded assessments, investigates reported problems, and retains attributed
failures for regression evaluation and tuning.

The normal workflow no longer requests historical labels or completion of a
blinded comparison. Preserve historical evaluations and reusable benchmark
execution/reporting capabilities. Optional, deliberately prepared benchmarks
remain engineering tools outside normal feature completion and Inbox work.

| Alternative | Assessment |
| --- | --- |
| Continue mandatory human comparison with a better form | Better presentation cannot remove the cost of reconstructing requirements or make it useful for every delivered feature. |
| Add quick feedback alongside the existing mandatory workflow | Duplicates effort and leaves the original dependency in place. |
| Remove every benchmark and rely only on feedback | Loses controlled comparison of reviewer versions and coverage of failures users do not notice or report. |
| Count silence as verified success and tune directly from votes | Confuses exposure with correctness, and feature dissatisfaction with a particular assessment error. |

## Feedback and evaluation policy

Feedback is optional. A vote saves immediately; explanations and correct
classification are not prerequisites. Users may report a problem without
first identifying its feature. Paid may suggest a link afterward.

| Signal | Meaning | Evaluation treatment |
| --- | --- | --- |
| No feedback | Default good for ordinary continuation; unexamined by a human | Provisional baseline, excluded from measured human approval. |
| Positive vote | The author confirms the identified behavior at that version | Explicit positive human evidence, limited to the selected scope. |
| Negative vote | The author reports a problem | Immediate negative user signal, whether or not details are supplied. |
| Attributed assessment failure | Investigation links a reported problem to a mistaken assessment | Negative assessment evidence with failure type, severity, and supporting links. |

Keep these evidence classes separate even if a future consumer projects them
into a numerical score. Exact weights and automatic tuning eligibility are
downstream decisions; defaults must not swamp sparse explicit feedback.
Human approval means confirmation of observed behavior, not authorization to
merge, release, change requirements, or execute new work.

An investigation cannot erase a negative vote or silently turn it positive.
An inconclusive investigation remains inconclusive. A fix in a later revision
does not make the original report incorrect. Approval of a feature does not
automatically approve every criterion, test, or assessment beneath it.

## Load-bearing assumptions

| Assumption | Status | Verification method | Concrete evidence or plan | If wrong |
| --- | --- | --- | --- | --- |
| Feedback can be traced to the implementation the author experienced | Pending | Trace a delivered feature and a later fix through revisions and assessments in the devcontainer | Validate against `FeatureIntent`, `FeatureIntentFacetAssessment`, `IntentConformanceVerdict`, and linked agent runs; retain unknown attribution when identity is unavailable | Collect feedback without assigning assessment penalties until traceability exists. |
| Quick votes are substantially less burdensome than corpus labeling | Pending | Observe an owner submitting positive and negative feedback, including a report without details | One-click save, visible confirmation, optional details, undo, and no requirement-document selection | Revise the interaction before expanding the pilot. |
| Existing quality/tuning infrastructure can consume explicit feedback without treating defaults as observations | Pending | Trace an attributed failure and an unexamined implementation through a report and regression evaluation | Inspect `QualityMetric`, existing collectors, and prompt-version evaluation; prove defaults do not enter human-approved counts | Keep feedback reports separate and defer score integration. |

## Prior-RDR impact

- **[RDR-067](RDR-067-approved-intent-conformance.md):** For autonomous
  operation, replace mandatory historical human comparison and related
  workflow dependencies with this feedback loop. Preserve verdict recording
  and optional benchmarks. Approval-gated conformance, amendments, measured
  promotion requirements, and merge guards remain authoritative for features
  explicitly using that policy. A missing verdict is never relabeled a pass.
- **[RDR-070](RDR-070-facet-confidence-and-clarification.md) and
  [RDR-071](RDR-071-confidence-driven-issue-delivery.md):** Add post-delivery
  evidence without replacing readiness, unresolved intent decisions, acceptance
  verification, or completion-blocking material follow-ups. Default good is
  not a higher confidence score or proof that an unrun test passed.
- **[RDR-009](RDR-009-prompt-evolution.md):** Supply traceable outcome evidence
  and regression cases. Do not authorize automatic prompt promotion, model
  changes, or unvalidated reward updates from raw votes.
- **[Delivery telemetry](../intent/delivery-telemetry/delivery-telemetry-design.md):**
  Keep the existing approval/amendment-based escaped-drift measure separate
  from user reports and attributed assessment failures. Report each signal's
  population and coverage; do not reinterpret historical metrics as feedback.
- **[RDR-077](RDR-077-automation-phases-and-work-item-authorization.md),
  [RDR-078](RDR-078-bounded-delivery-phase-authorization.md), and
  [RDR-080](RDR-080-project-delegation-after-settled-intent.md):** Feedback
  grants no execution authority. Investigation and corrective work require
  ordinary project/phase authorization and budget. Existing material intent,
  hold, security, review, and repository controls remain in force.

## Rollout Guard

This draft is docs-only and changes no runtime policy or flags.

Proposed implementation guard: a project-scoped `outcome_feedback` feature
flag, default off for new and existing projects. The first implementation
slice registers it in `FeatureFlags::DEFINITIONS` and checks
`FeatureFlags.enabled?(:outcome_feedback, project:)` at UI and agent/API
boundaries. An authorized owner/admin enables the pilot through the existing
feature-flag mechanism after the replacement prerequisite audit.

Opt-in switches autonomous projects to the new workflow and removes obsolete
benchmark tasks from their ordinary Inbox. Explicit approval-gated features
retain their policy. Rollback disables new feedback collection and automatic
investigation scheduling, preserves saved feedback and history, and does not
recreate mandatory comparison tasks for autonomous work. It never cancels
unrelated running agents. Background work rechecks the guard before starting.

Remove the temporary guard only after criterion-level closeout, the affected
work inventory, rollback validation, and pilot review establish a safe default.

## Minimum viable validation

In the devcontainer, demonstrate a delivered feature and criterion with
positive feedback, a negative vote without details, a detailed problem report,
undo/change, and a fix in a later revision. Verify that original votes retain
their author, scope, and version; another tenant cannot read or alter them;
repeated submissions do not duplicate votes or investigation jobs; and sparse
human evidence remains distinct from default good.

Trace a negative report to a mistaken assessment or an explicit unresolved
attribution. Preserve the report if Paid cannot substantiate the link. Show
that autonomous work does not require historical labeling, approval-gated
guards still apply, and feedback itself cannot admit corrective execution.
Record tested revision, environment, results, and missing capabilities. The
devcontainer is the only current operating environment; no production rollout
or measured reviewer accuracy is claimed by this proposal.

## LID handoff and delivery plan

- **HLD:** [Paid HLD](../high-level-design.md). Reconcile coverage truth,
  observability, confidence-driven delivery, and human authority after owner
  acceptance; this draft does not rewrite current platform policy.
- **Owning LLD/EARS:** Linked above, draft and unchecked. Related segments are
  [measured rollout](../intent/intent-conformance-rollout/intent-conformance-rollout-design.md),
  [quality feedback](../intent/quality-feedback-loops/quality-feedback-loops-design.md),
  and [facet confidence](../intent/facet-confidence/facet-confidence-design.md).
- **Implementation prerequisite:** Future issues must explicitly state
  "Blocked by Final RDR-082 and merged OUTCOME-FEEDBACK EARS claims" and name
  concrete issue dependencies once filed. No implementation tree is created
  or made eligible by this draft.
- **Delivery slices:** (1) reconcile policy/dependencies and ship feature votes
  with optional problem details; (2) criterion browsing and investigation with
  assessment attribution; (3) reporting/regression integration; (4) closeout
  and owner pilot acceptance. The first slice must deliver a useful feedback
  loop rather than only retire the old form.
- **Existing work:** Inventory open issues/PRs using current provider and Paid
  queue state. Continue unrelated work, retain automated assessment work,
  narrow mixed PRs, and mark obsolete labeling work superseded. Change explicit
  dependencies only after policy reconciliation. Do not claim old acceptance
  criteria passed or interrupt active owners merely because a draft exists.

## Finalization record

Pending owner review of this revision, resolution of load-bearing assumptions,
current issue/PR inventory, and HLD/LLD/EARS handoff. Before Final, record
contradictions and resolutions, assumption evidence, decisive validation,
pairwise prior-RDR reconciliation, and why review depth is proportionate under
the [authoring contract](future-authoring-contract.md). No owner acceptance,
implementation completion, or runtime adoption is implied.

## Closeout and post-mortem trigger

The future issue tree ends with criterion-level closeout and an umbrella
acceptance audit. Review the pilot after 30 days or ten distinct feedback
reports, whichever comes first; review sparse/no feedback honestly rather
than waiting indefinitely or declaring success. Examine submission friction,
attribution quality, duplicate work, preserved negative feedback, and whether
regression cases improved reviewer evaluation. Automatic tuning and broader
default enablement require separate evidence and an explicit decision.
