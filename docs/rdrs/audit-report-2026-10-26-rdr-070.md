# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Evidence issue**: [#4662](https://github.com/viamin/paid/issues/4662)
- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323)
- **Result**: **Human evidence pending; #4662 is not ready to close.** The
  evaluation flow is available, but no authenticated maintainer has supplied
  the blinded reference judgments for `facet-confidence-corpus-v1`.

## Criterion-level assessment

| Criterion | Status | Evidence / remaining action |
| --- | --- | --- |
| Start or resume from the originating Inbox item with frozen provenance | Ready for human action | `FacetConfidence::CloseoutEvaluationPacket` and `Start` bind the originating item, corpus digest, rubric, model, and input/source revisions. |
| One blinded reference judgment per corpus case, then freeze | Pending human action | The shipped labeling screen and `RecordLabel`/`FreezeLabels` require every case and hide expectations until freeze. No labels were authored during this audit. |
| Auditable authenticated maintainer identity | Ready for human action | The starter is the sole judge; `created_by`, `recorded_by`, and policy authorization reject agents, aliases, and other account members. |
| Preserve a correction after unblinding with its own reason | Shipped | `ReviseLabel` records one complete correction in the retained report under the authenticated sole judge while leaving the frozen label and its measures unchanged. |
| Attach compiled report and refresh this assessment | Pending human action | Freezing compiles and retains the report on the evaluation and returns it to the Inbox. It cannot exist until the maintainer records all judgments. This audit records that absence rather than inventing a report. |
| Keep policy-assessment framing and 80/80 / delivery guard | Preserved | The packet and report state that judgments are policy assessments, retain separate 80/80 defaults, and neither close the source issue nor enable delivery. |

## Required maintainer action

The authenticated maintainer must open #4323's partial-closeout Inbox item,
Start/Resume the facet-confidence evaluation, independently label all eight
cases while blinded, and freeze the set. They may then append a reasoned
post-unblinding correction if needed. The resulting compiled report is the
only evidence that can satisfy the remaining criteria; an agent-authored
label, generated inference, or bot session is not a substitute.

## Verification boundary

This audit inspected the current flow and its focused service/request specs.
No corpus verdict, band, readiness decision, citation, reason, correction, or
freeze was authored by the agent. Database-backed verification was not run:
the supplied `DATABASE_URL` uses a PostgreSQL role with `SUPERUSER` and
`BYPASSRLS`, which the application correctly rejects to protect tenant
isolation. The database guard and the RDR rollout guard remain unchanged.
