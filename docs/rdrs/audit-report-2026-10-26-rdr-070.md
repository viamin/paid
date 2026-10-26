# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This audit covers issue [#4662](https://github.com/viamin/paid/issues/4662),
the evidence-only dependency of RDR-070 closeout [#4323](https://github.com/viamin/paid/issues/4323).
It does not close either issue or enable delivery.

**Conclusion: human action required.** The shipped closeout-evaluation flow is
available for the frozen `facet-confidence-corpus-v1` corpus, but no
authenticated maintainer has recorded its eight blinded reference judgments.
An agent did not start an evaluation, author a label, freeze a set, or present
agent output as independent human evidence.

## Frozen evaluation identity

| Item | Evidence |
| --- | --- |
| Corpus | `facet-confidence-corpus-v1`, 8 cases |
| Corpus digest | `126b30c6b4796466f3057f78d0bedbb901e6fdb942ca14cafb7549ac396ecc0c` |
| Rubric / model | `facet-confidence-v1` / `claude-sonnet-4-6` |
| Required action | Authenticated maintainer starts or resumes from the #4323 Inbox item, records every blinded case judgment, then freezes the set. |

## Criterion-level assessment

| #4662 criterion | Evidence | Assessment |
| --- | --- | --- |
| Packet and Start/Resume show the frozen identity | `FacetConfidence::CloseoutEvaluationPacket` and `Start`; focused packet/start/request specs | Shipped; awaiting maintainer session |
| One blinded cited judgment per case before freeze | `RecordLabel`, `FreezeLabels`, and focused specs enforce sole judge, case evidence citations, no skips, and digest recheck | Human action required |
| Judge identity remains auditable | Evaluation and label records bind `created_by` / `recorded_by`; service requires the starter’s authenticated user ID | Shipped; no human evidence recorded yet |
| Corrections preserve originals | `FacetConfidenceEvaluationLabelRevision` and `ReviseLabel` append a judge-bound post-unblinding correction without changing the frozen label | Shipped in this change; runtime verification pending database availability |
| Compiled report and assessment refresh | `CompileReport` retains frozen judgments, expectations, divergences, citation compliance, provenance, and policy statement | Human action required before a report can exist |
| No calibration or delivery activation | RDR-070 guard and `CompileReport` state that labels are policy assessments, preserve 80/80 defaults, and neither enable delivery nor close the source issue | Satisfied |

## Required maintainer procedure

1. Open the originating #4323 partial-closeout Inbox item and select Start/Resume.
2. In the authenticated maintainer session, record all eight blinded judgments:
   verdict, intent band, technical band, readiness, one allowed evidence
   reference, and a reason.
3. Freeze the complete reference set. Review the report attached to the Inbox
   item, including divergences and citation compliance.
4. If unblinding changes a judgment, append a correction with its own reason;
   do not alter the frozen original.

The report remains an evidence artifact only: it is not a calibrated
probability exercise, does not change the 80/80 defaults, and does not enable
delivery.

## Verification notes

Dependencies completed with `bundle install` and `yarn install --frozen-lockfile`.
The supplied PostgreSQL endpoint was unavailable in this environment, so
`db:migrate` and database-backed specs could not run; the migration and
focused specs need execution against the configured application database.
