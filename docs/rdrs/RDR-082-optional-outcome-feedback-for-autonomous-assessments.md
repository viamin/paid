# RDR-082: Optional Outcome Feedback for Autonomous Assessments

## Metadata

- **Date**: 2026-11-23
- **Status**: Final
- **Type**: Product workflow and assessment evaluation
- **Owner decision**: Accepted on 2026-11-23 for the recommendation merged by
  [#5339](https://github.com/viamin/paid/pull/5339) at
  `d2ca47d7a12ad701b24e5bc7eefe65f7b1f9f538`. The acceptance finalizes this
  policy and its authority boundary; it does not claim implementation evidence,
  enable a flag, or authorize execution.
- **Related issues**: [#5341](https://github.com/viamin/paid/issues/5341)
  owns delivery. Its children remain separately admitted according to the
  prerequisites recorded below.
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
| Feedback can be traced to the implementation the author experienced | Resolved as a fail-closed contract | The 2026-11-27 read-only trace found project-scoped `FeatureIntent`, immutable approval revisions, exact-head/design `IntentConformanceVerdict` rows, and run-bound `QualityMetric` rows. None represents an experienced implementation revision for a general report. | P02 MUST persist only supplied known identities; unknown remains unknown. P05 may attribute an assessment only after it records the exact feature/criterion, implementation revision, assessment/verdict, and run links. | Save feedback with `attribution: unknown`; do not assign an assessment penalty. |
| Quick votes are substantially less burdensome than corpus labeling | Resolved as a pilot gate, not a claimed measurement | The accepted recommendation fixes the low-friction contract (immediate save, optional details, change/undo, no document selection); no shipped interaction exists to measure. | P03/P04 MUST demonstrate positive, negative-without-details, change, and undo in the devcontainer with an authorized operator before pilot expansion. | Revise the interaction; do not infer usability from this RDR or broaden the pilot. |
| Existing quality/tuning infrastructure can consume explicit feedback without treating defaults as observations | Resolved as a separate-evidence boundary | The 2026-11-27 read-only trace found `QualityMetric` has exactly one `human` row per agent run and a composite-score path, not an outcome-feedback source/history contract. | P06 MUST retain feedback and attribution outside `QualityMetric` until a versioned projection has source counts, a deduplication key, and an explicit scoring rule that excludes default good from human-observation counts. | Keep reports separate; no score integration, prompt/model promotion, or threshold change. |

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

This final decision is docs-only and changes no runtime policy or flags.

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

- **HLD:** [Paid HLD](../high-level-design.md) now records the final
  autonomous-operation boundary. This decision does not rewrite current
  platform policy or assert a shipped replacement.
- **Owning LLD/EARS:** Linked above, finalized as the unimplemented delivery
  contract. Their unchecked claims remain implementation work. Related segments are
  [measured rollout](../intent/intent-conformance-rollout/intent-conformance-rollout-design.md),
  [quality feedback](../intent/quality-feedback-loops/quality-feedback-loops-design.md),
  and [facet confidence](../intent/facet-confidence/facet-confidence-design.md).
- **Implementation prerequisite:** Each implementation issue must cite Final
  RDR-082, name the applicable OUTCOME-FEEDBACK claims, and identify concrete
  preceding issue dependencies. Final RDR-082 is necessary but never sufficient
  runtime authority: the flag, admission, tenant, project/phase authorization,
  budget, and review controls still apply.
- **Delivery slices:** (1) reconcile policy/dependencies and ship feature votes
  with optional problem details; (2) criterion browsing and investigation with
  assessment attribution; (3) reporting/regression integration; (4) closeout
  and owner pilot acceptance. The first slice must deliver a useful feedback
  loop rather than only retire the old form.
- **Existing work:** The finalization inventory below is dated evidence, not a
  command to interrupt owners. Continue unrelated work, retain automated
  assessment work, narrow mixed work only in its own scope, and do not claim
  superseded acceptance criteria passed.

## Finalization record

### Decision and decisive proof

The repository owner explicitly accepted the exact recommendation merged in
[#5339](https://github.com/viamin/paid/pull/5339) at
`d2ca47d7a12ad701b24e5bc7eefe65f7b1f9f538` on 2026-11-23 and asked that the
RDR be finalized. This is the decision evidence; Final follows the completed
2026-11-27 LID handoff and bounded read-only evidence below, not merger alone.
No material recommendation or authority-boundary change was made after that
acceptance.

### Identity, history, investigation, and trust contract

P02 must use durable, tenant-scoped records whose source-of-truth feedback row
has an immutable ID and records `project_id`, author, target kind/ID, known
feature/criterion identity, implementation revision, acceptance/design
revision, vote, submitted time, and state. A separate append-only history row
records every change or withdrawal with actor and time; it never overwrites the
original vote. Known feature identity is `FeatureIntent` plus its project;
criterion identity must include the feature and its immutable criterion key and
revision. Known assessment identity is the assessment/verdict ID plus its
recorded run and exact revision, not a guessed latest record.

The authorized investigation goal is to determine whether a retained negative
report can be supported as an assessment failure. Feedback text, GitHub text,
and agent-generated links are untrusted input. Deterministic code validates
tenant/project membership, identity shape, authorization, flag, budget,
deduplication, and state; only bounded semantic matching and attribution pass
through `agent_harness`. A negative report creates at most one open
investigation per feedback generation and target/revision identity. A detail
update appends history and updates that investigation's context; it cannot make
a parallel investigation. A new vote generation after withdrawal/change is
separate evidence, while a later fix does not rewrite the earlier report.

### Bounded evidence and contradictions resolved

The 2026-11-27 repository trace confirms that `FeatureIntent` is project-bound
and retains approved design revisions and approval history;
`IntentConformanceVerdict` binds an issue, project, exact PR head, approved
design revision, reviewer run, and outcome; and `QualityMetric` is unique by
`agent_run_id` and metric type. `FeatureIntentFacetAssessment` is tenant-bound
but has no general experienced-revision contract. Therefore prior text that
could imply complete attribution from those records is narrowed: the first
release preserves unknown context, and only explicit linked identities permit
assessment attribution. The same trace shows existing human metrics are not a
place to manufacture a default-good observation, resolving the quality-metric
contradiction by requiring a separate source-preserving projection.

### Pairwise effects and proportionality

- **RDR-067:** Mandatory historical comparison is retired only from autonomous
  operation after the guarded replacement ships. Approval-gated evaluation,
  amendments, merge guards, historical ledgers, and optional benchmarks remain.
  Closed #4594 is historical evaluation work, not failed acceptance evidence.
- **RDR-070 and RDR-071:** Feedback is post-delivery evidence; it changes
  neither confidence/readiness nor unresolved-decision and material-follow-up
  obligations.
- **RDR-009:** Only attributed, source-preserved regression evidence may enter
  a future evaluation; raw votes and silence cannot tune or promote anything.
- **Delivery telemetry:** Its approval/amendment escaped-drift population stays
  separate. Outcome reports must disclose their own population and coverage.
- **RDR-077, RDR-078, and RDR-080:** A report and its investigation create no
  execution, continuation, merge, release, or delegation authority. Any
  corrective work repeats ordinary admission and bounded authority checks.

This documentation review is proportionate: it resolves the policy boundary,
identity contract, and affected-work dependencies without simulating a user
flow that no runtime implementation exists to execute. The required P03–P07
tests and operating-devcontainer demonstrations remain the decisive evidence
for behavior and pilot expansion.

### Affected-work inventory (observed 2026-11-27)

GitHub API reads and a read-only Paid database query supplied this snapshot.
The database held no local `issues` or `agent_runs` rows for issues 412, 4525,
4594, 4983, and 5339–5348 at the observation time, so no Paid queue/run owner
exists to interrupt.

| Work | State at observation | Classification and action |
| --- | --- | --- |
| #5341 and #5342 | Open | Retained umbrella and finalization record. #5342 supplies this prerequisite; it does not admit runtime work. |
| #5343–#5348 | Open | Retained ordered delivery work. Their declared dependencies are the only tree dependencies added by this decision. |
| #5340 | Closed PR | Retained reusable benchmark/evaluation UX repair; related, not a replacement prerequisite. |
| #4594 | Closed | Narrowed historical solo-maintainer evaluation work. Its mandatory-labeling role is superseded only for autonomous operation; its preserved benchmark and approval-gated evidence remain valid history. |
| #412 | Closed | Unrelated legacy GitHub reaction/review metric proposal. Reuse its `QualityMetric` vocabulary only where evidence semantics match; do not revive reaction sentiment as outcome feedback. |
| #4525 | Closed | Unrelated maintenance proposal. Reuse its deduplication and separate-authority principle; no dependency or execution authority follows. |
| #4983 | Open | Retained related evidence-receipt work. Reuse bounded revision/digest receipts when available; it is not a blanket prerequisite for outcome-feedback delivery. |

No issue was relabeled, reopened, paused, or given a blanket dependency by this
inventory. Superseding a historical workflow requirement never says that its
old acceptance criteria passed.

## Closeout and post-mortem trigger

The future issue tree ends with criterion-level closeout and an umbrella
acceptance audit. Review the pilot after 30 days or ten distinct feedback
reports, whichever comes first; review sparse/no feedback honestly rather
than waiting indefinitely or declaring success. Examine submission friction,
attribution quality, duplicate work, preserved negative feedback, and whether
regression cases improved reviewer evaluation. Automatic tuning and broader
default enablement require separate evidence and an explicit decision.
