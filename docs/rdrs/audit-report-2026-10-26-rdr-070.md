# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

Tracks [#4662](https://github.com/viamin/paid/issues/4662), a prerequisite of
the RDR-070 closeout [#4323](https://github.com/viamin/paid/issues/4323). This
audit does not close either issue or the #4309 umbrella.

## Conclusion

**Human action required; reference evidence not established.** The shipped
evaluation flow was rechecked against the RDR-070 closeout requirements and
the corpus remains unjudged. An agent must not author reference labels or
represent an agent-authored record as independent human validation. The next
action is for the authenticated maintainer to use the originating closeout's
Inbox item to complete and freeze all corpus judgments in their own session.

## Criterion-level assessment

| #4662 criterion | Current evidence | Assessment |
| --- | --- | --- |
| Start or resume from the originating Inbox item with corpus identity, rubric, model, and revisions | `FacetConfidence::CloseoutEvaluationPacket`, `Start`, and the partial-closeout Inbox view bind `facet-confidence-corpus-v1` to its digest, `facet-confidence-v1`, `claude-sonnet-4-6`, input revisions, and source revision. | Shipped; awaiting maintainer use. |
| One blinded judgment per case before expectations are visible, then freeze | `RecordLabel`, `CaseView`, and `FreezeLabels` enforce per-case verdict, bands, readiness, cited evidence, reason, full labeled coverage, and the blind/freeze boundary. | Shipped; no human labels recorded. |
| Auditable authenticated judge identity | The evaluation's `created_by`, every label's `recorded_by`, controller authorization, and sole-judge service guard use the authenticated user record. | Shipped; awaiting authenticated maintainer action. |
| Preserve original labels after unblinding and record a correction reason | `ReviseLabel` appends a reasoned, attributable post-unblinding revision to the immutable evaluation report, without changing the original frozen label or its scored comparison. | Shipped; no correction recorded. |
| Compiled report and closeout assessment | `CompileReport` retains frozen judgments, expected bands, divergence and citation measures, and revisions. The report remains attached to the evaluation and reachable from the Inbox item. | Shipped; report cannot be evidence until labels are frozen. |
| Policy-only assessment; retain 80/80 and no delivery enablement | The report states that its judgments are policy assessments, does not enable delivery, and does not change the independent 80/80 defaults. | Verified. |

## Verification

Focused service and request coverage passed on 2026-10-26:

`bin/rspec spec/services/facet_confidence/closeout_evaluation/revise_label_spec.rb spec/services/facet_confidence/closeout_evaluation/record_label_spec.rb spec/services/facet_confidence/closeout_evaluation/freeze_labels_spec.rb spec/requests/projects/facet_confidence_evaluations_spec.rb`

Result: **28 examples, 0 failures**.

## Remaining human prerequisite

The authenticated maintainer must start or resume the evaluation from #4323's
Inbox item, independently judge all eight cases while blinded, freeze the
reference set, and then attach or link the resulting compiled report to the
closeout. Once that record exists, refresh this audit with the report identity,
judgment timestamp, divergence/citation measures, and any preserved revisions.
