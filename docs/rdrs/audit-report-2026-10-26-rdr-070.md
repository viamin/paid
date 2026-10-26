# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

Tracks [#4662](https://github.com/viamin/paid/issues/4662), the evidence-only
child of [#4323](https://github.com/viamin/paid/issues/4323). This is not a
closeout of either issue or the shared umbrella.

## Decision

**Human action required; do not close #4662.** No authenticated maintainer
session has recorded and frozen the eight blinded reference judgments for
`facet-confidence-corpus-v1`. An agent must not create those labels or present
agent-authored values as independent human validation.

## Criterion-level assessment

| Criterion | Evidence | Status |
| --- | --- | --- |
| Start or resume from the originating Inbox item with corpus provenance | `CloseoutEvaluationPacket`, `CloseoutEvaluation::Start`, and `Projects::FacetConfidenceEvaluationsController`; `spec/services/facet_confidence/closeout_evaluation/start_spec.rb` and `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Shipped; awaiting maintainer use |
| Record every blinded reference judgment and freeze the set | `RecordLabel` validates one case-local citation and `FreezeLabels` blocks pending/skipped cases before compiling the report; focused service/request specs cover the flow | Shipped; no human reference set exists |
| Keep authenticated judge identity auditable | `created_by` and `recorded_by` are authenticated `User` associations; services reject anyone other than the evaluation starter | Shipped; awaiting maintainer session |
| Preserve a post-unblinding correction and its reason | `ReviseLabel` appends `revised_*` values, actor, time, and correction reason; original values remain the report scoring input | Shipped by this change; awaiting maintainer use |
| Attach the compiled report and refresh the RDR assessment | `CompileReport` persists the report on the evaluation and exposes it from the Inbox evaluation; this document records the current assessment | Shipped; report awaits a frozen human set |
| Retain policy-only meaning and 80/80 defaults | The compiled report and surface state that judgments are not calibrated probabilities and never enable delivery or alter 80/80 | Satisfied |

## Required maintainer procedure

In the authenticated maintainer session, open the originating partial-closeout
Inbox item for #4323, inspect the packet, and Start/Resume its evaluation.
For each of the eight cases, independently select verdict, intent band,
technical band, readiness, one case-local evidence reference, and a reason
without viewing shapes, selection rationale, or frozen expectations. Freeze
only after all eight are labeled. The persisted compiled report then supplies
the frozen comparison, divergences, and citation-compliance evidence for this
audit. If the maintainer changes a reading after unblinding, use the
post-unblinding correction control and record the correction reason; it does
not rescore the blinded set.

## Rollout guard

RDR-070 remains in shadow mode. The report is evidence only: it neither closes
the closeout nor enables delivery, changes project policy, or changes the independent
80/80 defaults.
