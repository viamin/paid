# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

This criterion-level assessment covers issue [#4662](https://github.com/viamin/paid/issues/4662),
the reference-judgment evidence required by closeout
[#4323](https://github.com/viamin/paid/issues/4323). It does not close either
closeout or the [#4309](https://github.com/viamin/paid/issues/4309) umbrella.

**Conclusion: blocked on the authenticated maintainer.** The shipped flow can
present the corpus packet, collect a sole-maintainer blinded reference set,
freeze it, and retain the comparison report. No authenticated maintainer
judgment set or frozen compiled report was present in this agent session.
Agent-authored labels would not be independent human evidence and were not
created.

## Criterion-level assessment

| #4662 acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Start or resume from the originating Inbox item with corpus digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `Start`, and the partial-closeout Inbox view provide the packet and persisted Start/Resume entry point. | Implemented; requires maintainer session |
| One blinded judgment for every corpus case, then freeze | `RecordLabel` accepts the required verdict, bands, readiness, citation, and reason while `CaseView` excludes shapes, rationale, and expected values; `FreezeLabels` rejects incomplete or skipped sets and compiles the report. | Implemented; no human labels recorded |
| Authenticated maintainer identity is auditable | The evaluation binds `created_by`; label writes bind `recorded_by`; service and policy checks restrict the judge actions to that same authenticated user. | Implemented; no maintainer session evidence |
| Correct post-unblinding judgment without overwriting the original | `ReviseLabel` permits the sole judge to append one reasoned frozen-only correction in separate `revised_*` fields. The original label and frozen report are retained unchanged. | Implemented; focused service and request coverage passed |
| Attach compiled report and refresh the criterion assessment | `CompileReport` retains judgment/expectation divergences and citation compliance on the evaluation, which the Inbox links back to. This document records the present missing human-evidence prerequisite. | Implemented; report not yet produced |
| Preserve 80/80 policy and do not enable delivery | The compiled report explicitly identifies judgments as policy assessments and states it cannot close the issue, enable delivery, or change the 80/80 defaults. | Satisfied |

## Required maintainer action

1. Open the partial-closeout Inbox item for #4323 and start or resume its
   `facet-confidence-corpus-v1` evaluation.
2. In the authenticated maintainer session, independently record every blinded
   corpus judgment, with one allowed case-evidence citation and a reason.
3. Freeze the fully labeled set and retain the generated report on the
   closeout. If unblinding changes the maintainer's reading, append the
   reasoned correction; do not alter the original label.
4. Replace this blocked status with the report's actual corpus digest, judge
   attribution, freeze timestamp, divergence counts, and citation-compliance
   result.

The 80/80 defaults remain provisional policy thresholds, not calibrated
probabilities. This evidence exercise neither enables delivery nor changes
readiness enrollment.
