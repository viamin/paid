# RDR-070 Closeout Evidence Refresh — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323) (C70)
- **Follows**: [RDR Closeout Checklist](closeout-checklist.md)
- **Status decision**: **Partially Implemented**
- **Tracks**: [#4309](https://github.com/viamin/paid/issues/4309); this audit does not close the umbrella.

## Scope and conclusion

This refresh reconciles the accepted RDR, the facet-confidence LLD/EARS, and
the current implementation. It treats code and executed tests as evidence,
not historical issue closure. The deterministic contracts are shipped. The
remaining criterion is measured acceptance: authentic blinded human-reference
judgments and the resulting evaluator report. Native child
[#4596](https://github.com/viamin/paid/issues/4596) owns that workflow; its
queued recovery run 14475 superseded the timed-out run 14424. No new audit or
corpus fixture is a substitute for that evidence.

## Criterion-by-criterion evidence

| EARS claim | Shipped evidence |
| --- | --- |
| `001` separate bounded scores and explicit unknown | `app/models/feature_intent_facet_assessment.rb`; `spec/models/feature_intent_facet_assessment_spec.rb`; schema constraints in `db/migrate/20261017141954_create_feature_intent_facet_confidence_records.rb:76-93`. |
| `002` attributable, versioned agent assessment | `app/services/feature_intents/assess_facet.rb`; `app/jobs/feature_intents/assess_facet_job.rb`; `spec/services/feature_intents/assess_facet_spec.rb`. |
| `003` correction precedence and disagreement clarification | `app/services/feature_intents/challenge_facet_assessment.rb`; `spec/services/feature_intents/challenge_facet_assessment_spec.rb`. |
| `004` no duplicate or incidental-interaction agreement | `app/services/feature_intents/ingest_facet_evidence.rb`; `spec/services/feature_intents/ingest_facet_evidence_spec.rb`. |
| `005` chat challenge and visible reassessment | `app/services/feature_intents/challenge_facet_assessment.rb`; `spec/services/feature_intents/challenge_facet_assessment_spec.rb`. |
| `006` discriminating comparative/conditional/free-text clarification | `app/services/chat_sessions/build_system_prompt.rb`; `spec/services/chat_sessions/build_system_prompt_spec.rb`. |
| `007` explicit preference provenance and authorized lifecycle | `app/services/explicit_preferences/`; `app/mcp/tools/*explicit_preference.rb`; `spec/mcp/tools/save_explicit_preference_spec.rb`. |
| `008` prerequisite rationale, design baseline, no vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`; `app/models/feature_intent_issue_prerequisite.rb`; their model specs. |
| `009` independent per-prerequisite readiness | `app/services/feature_intents/scoped_readiness.rb:29-76`; `spec/services/feature_intents/scoped_readiness_spec.rb`. |
| `010` bounded, independently authorized 80/80 defaults | `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb:5-18`; `spec/services/feature_intents/scoped_readiness_spec.rb`. |
| `011` research-scope rather than implementation-answer readiness | `app/services/feature_intents/scoped_readiness.rb`; `spec/services/feature_intents/scoped_readiness_spec.rb`. |
| `012` failed, invalid, stale, and unknown assessments fail closed | `app/services/feature_intents/scoped_readiness.rb:51-75`; `spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb`. |
| `013` builder context preserves scores, evidence, and provenance categories | `app/services/feature_intents/admitted_intent_context.rb`; `app/services/prompt_assembly/sections/admitted_intent.rb`; `spec/services/feature_intents/admitted_intent_context_spec.rb`. |
| `014` rendering reads persisted assessment without synchronous LLM calls | `app/services/chat_sessions/build_system_prompt.rb`; `spec/services/chat_sessions/build_system_prompt_spec.rb`. |
| `015` later findings follow delivery policy without pausing a run | `app/services/design_amendments/evaluate_impact.rb`; `spec/services/design_amendments/evaluate_impact_spec.rb`. |
| `016` frozen, representative versioned corpus | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`; `lib/facet_confidence/assessment_corpus_ledger.rb:18-46`; `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`. |
| `017` provenance, serialization, replay and correction guards | `lib/facet_confidence/assessment_corpus_ledger.rb:67-118`; `bin/facet-confidence-assessment-evaluation`; `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb`. |
| `018` false-readiness, clarification, correction, cost, and rework reporting | `lib/facet_confidence/assessment_outcome_report.rb`; `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`; operator worksheet records all live measures as not established. |
| `019` structured feature-decision response with explicit attribution | `app/services/feature_intents/respond_to_decision.rb`; `spec/services/feature_intents/respond_to_decision_spec.rb`; `spec/views/dashboard/inbox_detail_feature_decision_partial_spec.rb`. |
| `020` authorized closeout packet and digest-pinned Start/Resume | `app/services/facet_confidence/closeout_evaluation_packet.rb`; `app/services/facet_confidence/closeout_evaluation/start.rb`; `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb`. |
| `021` sole-judge blinded labels, readiness consistency, freeze/report | `app/services/facet_confidence/closeout_evaluation/record_label.rb`; `freeze_labels.rb:27-68`; `case_view.rb:12-69`; `spec/services/facet_confidence/closeout_evaluation/{record_label,freeze_labels}_spec.rb`. |

The `79/80` behavior is directly asserted by
`spec/services/feature_intents/scoped_readiness_spec.rb`: exactly 80/80 is
ready; either independent 79 score is not ready and cannot be averaged away.
Unknown, missing, pending, stale, non-finite, and out-of-range values are
explicit blockers in `ScopedReadiness`. The corpus worksheet separately records
that 80/80 are provisional policy defaults rather than calibrated probabilities
and blocks throughput-only tuning.

## Measured-acceptance gap

The shipped corpus machinery intentionally reports `not established` until
operators execute the frozen corpus. The outcome worksheet currently contains
zero recorded live cases, so false readiness, unnecessary clarification, human
corrections, assessment cost, downstream rework, and operational failures have
not been measured. Fixture-ledger tests prove calculation and guard behavior;
they do not supply human-reference judgments.

[#4596](https://github.com/viamin/paid/issues/4596) is already the focused
owner for the authenticated, blinded reference-judgment workflow. Its packet,
sole-judge authorization, save/resume behavior, digest recheck, citation
validation, and reproducible freeze report are shipped. The remaining action
is to complete that actual evaluation, retain its report, and rerun this
closeout against the resulting measurements. No duplicate child issue is
filed.

## Rollout guard and closure disposition

RDR-070's shadow-mode guard remains enforced. This audit does not enable
delivery, change thresholds, enroll existing features, or pause active work.
The default 80/80 values remain provisional judgments, not calibrated
probabilities, and cannot be tuned solely to improve throughput.

**Do not close #4323 or #4309.** RDR-070 remains Partially Implemented until
[#4596](https://github.com/viamin/paid/issues/4596) supplies the measured human-reference evidence. The required rerun
condition is a completed, frozen #4596 evaluation with its retained report and
the authentic corpus outcome measures established.

## Verification

`bundle install` and `yarn install --frozen-lockfile` completed. Rails database
preparation and the focused RSpec suite could not run in this environment: the
provided PostgreSQL credential is a `SUPERUSER`/`BYPASSRLS` role and the
application's `Database::RuntimeRoleGuard` correctly refuses to boot with it.
The guard was not bypassed. This is a verification-environment limitation, not
evidence that the measured acceptance gap is resolved.
