# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This audit covers [#4662](https://github.com/viamin/paid/issues/4662), the
reference-judgment evidence required by closeout
[#4323](https://github.com/viamin/paid/issues/4323). It does not close either
closeout or the RDR-070 umbrella.

**Conclusion: human prerequisite pending.** The shipped workflow can start or
resume one digest-pinned `facet-confidence-corpus-v1` evaluation, keep its
labels blinded, freeze a complete reference set, and retain its comparison
report. No authenticated maintainer has recorded the eight required judgments
in this audit, so no report, divergence measure, or citation-compliance result
is claimed here. An agent must not supply those labels or present them as
independent human validation.

## Criterion-level assessment

| #4662 criterion | Current evidence | Status |
| --- | --- | --- |
| Start/resume from the originating Inbox item with corpus digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `FacetConfidence::CloseoutEvaluation::Start`, and `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Implemented; human action pending |
| One blinded judgment for every corpus case and explicit freeze | `RecordLabel` validates all six judgment fields and case-local citations; `FreezeLabels` rejects pending or skipped cases | Human action pending |
| Auditable authenticated-maintainer identity | The evaluation records `created_by`; labels record `recorded_by`; service and policy restrict label/freeze actions to the initiating operator | Implemented; no judgment provenance yet exists |
| Preserve original labels when corrected after unblinding | `ReviseLabel` appends a complete reasoned correction with actor and timestamp; the original blinded values remain the comparison basis | Implemented; no correction has been made |
| Attach compiled report and refresh this assessment | `FreezeLabels` invokes `CompileReport`, which retains frozen judgments, expectations, divergences, and citation compliance on the evaluation | This audit is refreshed; compiled human report pending |
| Keep judgments as policy assessments; preserve 80/80 defaults and delivery guard | The report states this policy boundary; `ScopedReadiness` remains the separate 80/80 enforcement path | Implemented |

## Required maintainer action

An authenticated project maintainer must open the partial-closeout Inbox item
for #4323, use Start evaluation or Resume labeling, and independently record a
verdict, intent band, technical band, readiness, case-local cited evidence, and
reason for each case before freezing. The maintainer may then inspect the
compiled report and, if needed, append a reasoned correction after unblinding.
That report is the only evidence that can satisfy the outstanding human-label
criteria.

## Policy boundary

The frozen corpus and its labels assess policy interpretation, not calibrated
probabilities. This audit neither changes the separate 80/80 defaults nor
enables delivery.
