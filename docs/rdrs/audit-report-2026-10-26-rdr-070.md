# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323)
- **Evidence work item**: [#4662](https://github.com/viamin/paid/issues/4662)
- **Corpus**: `facet-confidence-corpus-v1`
- **Conclusion**: **Human prerequisite outstanding; do not close #4662 or
  #4323.**

This bounded audit rechecks the RDR-070 closeout-evaluation surface against
the approved RDR, facet-confidence LLD, and `FACET-CONFIDENCE-020` and `021`.
It does not invent, submit, freeze, or characterize reference judgments.
Those are human evidence and must be entered by the authenticated maintainer
in their own session.

## Criterion-level assessment

| Criterion | Current evidence | Assessment |
| --- | --- | --- |
| Start or resume from the originating partial-closeout Inbox item, with corpus digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `Start`, the Inbox partial-closeout view, and `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Shipped; awaiting maintainer use |
| One blinded judgment per corpus case, then freeze | `RecordLabel`, `FreezeLabels`, `CaseView`, and focused service/request specs enforce the sole-judge, full-coverage, citation, and blinding rules | Human prerequisite outstanding |
| Auditable authenticated judge identity | Evaluation `created_by`, label `recorded_by`, authorization policy, and structured lifecycle logs retain the authenticated sole judge | Shipped; no maintainer judgment set recorded by this audit |
| Preserve a post-unblinding correction with its reason | `RecordCorrection` appends `revised_*` fields, actor, timestamp, cited evidence, and reason without changing the original label or frozen report | Shipped; awaiting any maintainer correction |
| Attach compiled report and refresh this assessment | `CompileReport` retains the frozen comparison, divergences, citation compliance, and provenance on the evaluation and returns it to the Inbox item; this document records the current disposition | Report cannot exist until the maintainer completes and freezes all labels |
| Keep assessments as policy judgments; do not alter 80/80 or enable delivery | RDR-070 rollout guard and report/packet copy keep the evaluation evidentiary only; no threshold, enrollment, or delivery changes are introduced here | Satisfied |

## Required maintainer action

From the originating closeout's Inbox item, the authenticated maintainer must:

1. Start or resume the evaluation after checking the displayed corpus digest,
   rubric, model, source revision, and input revisions.
2. Independently record every blinded judgment with the required verdict,
   bands, readiness, cited evidence reference, and reason.
3. Freeze the complete reference set and attach the retained compiled report to
   the closeout evidence.
4. If unblinding changes a judgment, append the reasoned correction; do not
   rewrite the frozen label or report.

Only that authenticated maintainer action can satisfy #4662. An agent may
navigate the packet or verify the mechanics, but cannot author labels or
present them as independent human validation.

## Rollout and closure disposition

RDR-070's rollout guard remains in force: assessment is policy evidence, not
calibration or release authorization. The separate 80/80 defaults remain
unchanged, no delivery path is enabled, and the work item does not close the
RDR-070 closeout or umbrella.
