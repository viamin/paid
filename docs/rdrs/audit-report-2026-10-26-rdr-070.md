# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This audit covers issue [#4662](https://github.com/viamin/paid/issues/4662),
the human-evidence dependency of the RDR-070 closeout
[#4323](https://github.com/viamin/paid/issues/4323). It does not close either
the closeout or the shared umbrella.

**Conclusion: human prerequisite outstanding.** The shipped Inbox entry,
blinded-labeling flow, freeze, report, and audited post-unblinding correction
path are available. No authenticated maintainer session has recorded the eight
independent reference judgments for `facet-confidence-corpus-v1`; therefore no
compiled judgment comparison, divergence count, or citation-compliance result
is claimed here.

## Criterion-level assessment

| Criterion | Evidence | Status |
| --- | --- | --- |
| Start or resume from the originating closeout Inbox item with digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `Start`, and the Inbox partial implement `FACET-CONFIDENCE-020`. | Ready for authenticated maintainer |
| Record one blinded judgment for each corpus case and freeze the reference set | `RecordLabel`, `CaseView`, and `FreezeLabels` implement `FACET-CONFIDENCE-021`; labels remain absent from this audit. | Blocked on authenticated maintainer |
| Keep the judge identity auditable | Evaluation `created_by`, label `recorded_by`, sole-judge policy, and RLS attach records to the authenticated user. | Ready for authenticated maintainer |
| Preserve a correction after unblinding | `FacetConfidenceEvaluationLabelRevision` retains one complete correction, actor, timestamp, and reason without changing the original blinded label or its comparison (`FACET-CONFIDENCE-022`). | Implemented; no human correction recorded |
| Attach compiled report with comparison, divergences, and citation compliance | `CompileReport` retains the report on the evaluation and refreshes it after a correction. | Blocked until labels are frozen |
| Keep assessments policy-only, with 80/80 defaults and delivery unchanged | The packet and report explicitly state this boundary; the correction path does not touch readiness admission, thresholds, or delivery. | Satisfied |

## Maintainer procedure

An authenticated maintainer must open the #4323 Inbox item, start or resume
the evaluation, independently label every case without exposing frozen
expectations, and freeze the set. The generated report then becomes the
closeout attachment. If unblinding warrants a correction, use the post-freeze
correction control and state its reason; the original judgment remains the
reference comparison.

## Verification note

Dependencies were installed with `bundle install` and `yarn install
--frozen-lockfile`. `bin/rails db:prepare` can connect only when adapted to the
provided database endpoint, but normal Rails boot rejects its supplied
`agent` PostgreSQL role because it has `SUPERUSER` and `BYPASSRLS`. The guard
is intentional and was not bypassed. Database-backed migration and RSpec
verification require a non-superuser application role.
