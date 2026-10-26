# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This is the criterion-level evidence audit for issue
[#4662](https://github.com/viamin/paid/issues/4662), part of RDR-070 closeout
[#4323](https://github.com/viamin/paid/issues/4323). It tracks the supplied
reference-judgment evidence only; it does not close #4323 or the shared
umbrella.

**Conclusion: human prerequisite pending.** The shipped closeout-evaluation
flow can now preserve a blinded judgment and append an auditable correction
after unblinding. No authenticated maintainer has recorded the corpus labels
in this evidence generation. This audit therefore does not manufacture a
reference set, report, divergence result, or claim of independent human
validation.

## Criterion-level assessment

| #4662 acceptance criterion | Evidence | Assessment |
| --- | --- | --- |
| Start or resume the originating closeout evaluation from Inbox with digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `FacetConfidence::CloseoutEvaluation::Start`, and the partial-closeout Inbox view; focused packet/start/request specs | Shipped; needs maintainer operation for this closeout |
| Record one blinded judgment per corpus case and freeze before expectations are visible | `RecordLabel`, `FreezeLabels`, `CaseView`, and focused service/request specs enforce all-case labeling, cited evidence, and blinding | Pending authenticated-maintainer action; no labels were authored by this audit |
| Keep the judge identity auditable and exclude agents, aliases, and bots | Evaluation and labels bind `created_by`/`recorded_by`; policy and services require the initiating authenticated operator to label or freeze | Shipped control; pending maintainer evidence |
| Preserve original labels and record a correction with its own reason after unblinding | `FacetConfidenceEvaluationLabelRevision`, `ReviseLabel`, report revision history, and `revise_label_spec` retain the immutable original plus actor, timestamp, corrected judgment, and correction reason | Shipped |
| Attach the compiled report and refresh closeout assessment | `CompileReport` retains report data/markdown on the frozen evaluation and returns it to the originating Inbox item | Pending: it can only exist after the maintainer freezes the actual reference set; this document is the refreshed no-evidence assessment |
| Keep judgments as policy assessments; do not tune 80/80 or enable delivery | Report and Inbox language retain that policy; revision operations do not touch thresholds or delivery state | Satisfied |

## Required maintainer operation

The authenticated maintainer must open the originating partial-closeout Inbox
item, select Start/Resume, independently label every `facet-confidence-corpus-v1`
case without exposing frozen expectations, and freeze the set. The application
then attaches the compiled report to that Inbox item. If the maintainer changes
a view after unblinding, they must use the correction action and give a
correction reason; the report retains both the original blinded label and the
revision history.

The resulting report must be used to update this audit with the actual corpus
digest, judge identity, freeze time, per-case divergences, and citation
compliance. Until then, those facts are **not established**.

## Rollout guard

The RDR-070 shadow-mode guard remains unchanged. This evidence workflow does
not enable confidence-driven delivery, alter the independent default intent or
technical threshold of 80/100, or treat policy bands as calibrated
probabilities.
