# RDR-070 Closeout Evaluation Audit — 2026-10-26

<!-- @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-021 @spec FACET-CONFIDENCE-022 -->

## Scope and conclusion

This refresh evaluates the reference-judgment evidence required by #4662 for
RDR-070 closeout #4323. It does not close #4323 or the shared umbrella.

**Conclusion: human prerequisite pending.** The shipped application can start
and resume the digest-pinned blinded evaluation, attribute every label to its
authenticated sole judge, freeze a complete set, and retain its compiled
comparison report. No authenticated maintainer has recorded the eight reference
judgments in this run. Consequently there is no truthful frozen report to
attach and no outcome measurement to claim.

## Criterion-level assessment

| Criterion | Current evidence | Result |
| --- | --- | --- |
| Start/resume shows frozen corpus identity, rubric, model, source and input revisions | `CloseoutEvaluationPacket`, `Start`, and its focused spec pin one evaluation to the originating issue and corpus digest. | Shipped; awaiting maintainer action. |
| One blinded judgment per case before expectations are visible, then freeze | `CaseView` whitelists only case evidence and thresholds; `RecordLabel` requires all six judgment fields; `FreezeLabels` rejects unlabeled or skipped cases and compiles the report atomically. | Shipped; no labels recorded. |
| Judge identity is auditable and not agent-authored | The evaluation records `created_by`; every label records `recorded_by`; write and freeze services require that same authenticated user. | Shipped; no maintainer session has supplied evidence. |
| Corrections preserve originals and state a reason | `ReviseLabel` is available only after freeze to the original judge, records separately attributed revised fields and a required reason, and leaves frozen report measures unchanged. | Shipped; no correction recorded. |
| Compiled report returns to closeout | `CompileReport` stores corpus provenance, labels, expected bands, divergences, and citation compliance on the frozen evaluation; the Inbox links it to the originating item. | Shipped; unavailable until the human freezes the set. |
| No probability calibration, threshold change, or delivery enablement | The report states that judgments are policy assessments and does not close the issue, enable delivery, or change the independent 80/80 defaults. | Preserved. |

## Required human action

The authenticated maintainer must open the partial-closeout Inbox item for
issue #4323, start or resume its facet-confidence evaluation, and independently
label every case before freezing. They may then append a reasoned correction
after unblinding if necessary. The resulting persisted report—not this audit—
is the evidence to attach to the closeout.

## Verification

Focused service and request specs cover the start/resume, blinding, label,
freeze, report, authorization, and correction contracts. This change was
verified with the focused facet-confidence closeout specs and the repository
coherence check; database preparation used the supplied PostgreSQL service.
