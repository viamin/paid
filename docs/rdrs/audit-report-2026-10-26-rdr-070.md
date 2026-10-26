# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This is the criterion-level evidence assessment for issue
[#4662](https://github.com/viamin/paid/issues/4662), part of RDR-070 closeout
[#4323](https://github.com/viamin/paid/issues/4323). It supplies the
reference-judgment evidence only; it neither closes the closeout nor the
shared umbrella.

**Conclusion: human action remains required.** The shipped closeout-evaluation
flow displays the immutable packet, binds the authenticated starter as the sole
judge, blinds frozen expectations until explicit freeze, and compiles the
comparison report. This change also adds a separately attributable,
post-unblinding correction record without overwriting the frozen measurement
input. No agent-authored judgment, frozen reference set, or report is claimed
by this audit.

## Issue #4662 acceptance assessment

| Acceptance criterion | Evidence | Assessment |
| --- | --- | --- |
| Start or resume from the originating Inbox item with corpus digest, rubric, model, and input revisions | `FacetConfidence::CloseoutEvaluationPacket`, `Start`, and the partial-closeout Inbox surface provide the packet and Start/Resume path, covered by `closeout_evaluation_packet_spec`, `start_spec`, and request coverage. | Shipped; awaiting authenticated maintainer action. |
| Record and freeze one blinded judgment per case | `RecordLabel`, `CaseView`, and `FreezeLabels` require a complete labeled set, hide shape/rationale/expectations before freeze, recheck the digest, and compile the report. | Shipped; no human reference judgments recorded by this agent. |
| Keep judge identity auditable | Evaluation `created_by`, label `recorded_by`, policy checks, and service guards require the starter's authenticated account for record, freeze, and correction actions. | Shipped; awaiting a maintainer session. |
| Preserve an original label after unblinding correction and record its reason | `ReviseLabel`, `revised_*` fields, the report compiler, and the report UI retain originals as measurement input and display one separately attributed, reasoned correction. | Shipped in this change; regression coverage added. |
| Attach compiled report and refresh criterion assessment | `CompileReport` retains provenance, original judgments, divergences, citation compliance, and separately reported corrections on the evaluation and Inbox-linked report surface. This document is the refreshed criterion assessment. | Report attachment is shipped; its human-evidence content awaits the maintainer. |
| Treat results as policy assessments; retain 80/80 defaults and do not enable delivery | Packet, report, and design text state this explicitly; the correction path does not touch thresholds or delivery policy. | Satisfied. |

## Human prerequisite and handoff

The authenticated maintainer must start or resume the evaluation from the
closeout's Inbox item, independently judge every case while blinded, and
freeze the set. They may then record a correction only after unblinding; its
reason is stored independently and does not alter frozen measures. This agent
must not fill these fields, use an alias, or represent its own labels as human
validation.

## Rollout guard

RDR-070 remains governed by shadow assessment and the complete RDR-071 delivery
path. This evidence flow neither enables delivery nor changes the provisional
80/80 defaults, and corrections do not rescore the frozen comparison.

## Verification status

Ruby and JavaScript dependencies were installed. The test database applied the
three migration steps (columns, concurrent reference index, then validated
foreign key), and focused RSpec completed with **38 examples, 0 failures**.
The development database remains deliberately unavailable because its supplied
role is both `SUPERUSER` and `BYPASSRLS`; `Database::RuntimeRoleGuard`
correctly rejects that unsafe tenant runtime role. Deploy with a non-bypass
application role before applying the migration outside the test environment.
