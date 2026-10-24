# EARS Specs: Facet Confidence

Status: P05 implements the durable facet/evidence and prerequisite-map foundation
for `001` and `008`; P06 implements assessment generation and persisted chat
context for `002`–`005`, `012`–`014`; P08 implements `006` and `007`; P09
implements `009` through `012`. The RDR-070 corpus deliverable (#4573)
implements `016`–`018`: the frozen assessment corpus, per-run provenance, and
outcome metrics machinery; operator-executed measured runs remain pending and
the worksheet records them as not established.

- [x] **FACET-CONFIDENCE-001** — When assessing a feature or issue facet, Paid SHALL represent intent certainty and technical confidence separately on a 0–100 scale and SHALL represent unknown values explicitly rather than inventing human intent.
  *Tests:* `spec/models/feature_intent_facet_assessment_spec.rb`.
  *Code:* `app/models/feature_intent_facet_assessment.rb`.
- [x] **FACET-CONFIDENCE-002** — When an agent produces a facet assessment, Paid SHALL record its evidence references, evidence revision, rubric/model version and concise explanation through the agent_harness interface.
  *Tests:* `spec/services/feature_intents/assess_facet_spec.rb`.
  *Code:* `app/services/feature_intents/assess_facet.rb`, `app/jobs/feature_intents/assess_facet_job.rb`.
- [x] **FACET-CONFIDENCE-003** — When human statements contradict earlier directions, Paid SHALL preserve attribution, honor explicit corrections over superseded evidence, and ask for clarification of unresolved disagreement rather than count statements as votes.
  *Tests:* `spec/services/feature_intents/challenge_facet_assessment_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb`.
  *Code:* `app/services/feature_intents/challenge_facet_assessment.rb`, `app/services/feature_intents/assess_facet.rb`.
- [x] **FACET-CONFIDENCE-004** — When assessing intent certainty, Paid SHALL NOT treat repeated agent suggestions, duplicated evidence or incidental UI interactions as additional human agreement.
  *Tests:* `spec/services/feature_intents/ingest_facet_evidence_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb`.
  *Code:* `app/services/feature_intents/ingest_facet_evidence.rb`, `app/services/feature_intents/assess_facet.rb`.
- [x] **FACET-CONFIDENCE-005** — When a user challenges an assessment in chat, Paid SHALL retain the challenge as evidence and reassess the affected facets with a visible explanation.
  *Tests:* `spec/services/feature_intents/challenge_facet_assessment_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`.
  *Code:* `app/services/feature_intents/challenge_facet_assessment.rb`, `app/services/chat_sessions/build_system_prompt.rb`.
- [x] **FACET-CONFIDENCE-006** — When uncertainty admits distinguishing questions, Paid SHALL ask context-appropriate comparative questions and allow conditional, both/neither and free-text answers.
  *Tests:* `spec/services/chat_sessions/build_system_prompt_spec.rb`.
  *Code:* `app/services/chat_sessions/build_system_prompt.rb`.
- [x] **FACET-CONFIDENCE-007** — When persisting a durable preference, Paid SHALL require an explicit user statement and an explicit or clarified scope, retain its provenance, and permit authorized inspection, correction and deletion; it SHALL NOT infer durable preferences from behavior.
  *Tests:* `spec/mcp/tools/save_explicit_preference_spec.rb`, `spec/models/explicit_preference_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/services/explicit_preferences/persist_spec.rb`, `spec/services/explicit_preferences/context_spec.rb`.
  *Code:* `app/mcp/tools/*explicit_preference.rb`, `app/models/explicit_preference.rb`, `app/services/chat_sessions/build_system_prompt.rb`, `app/services/explicit_preferences/`.
- [x] **FACET-CONFIDENCE-008** — When an issue's material prerequisites are mapped, Paid SHALL retain the agent's mapping rationale and coverage assessment, including relevant design documents, and SHALL NOT consider an unassessed empty mapping ready.
  *Tests:* `spec/models/feature_intent_issue_prerequisite_mapping_spec.rb`, `spec/models/feature_intent_issue_prerequisite_spec.rb`.
  *Code:* `app/models/feature_intent_issue_prerequisite_mapping.rb`, `app/models/feature_intent_issue_prerequisite.rb`.
- [x] **FACET-CONFIDENCE-009** — When evaluating initial issue readiness, Paid SHALL require each material facet's known intent and technical scores to meet their respective project thresholds without averaging across facets or requiring unrelated feature facets to pass.
- [x] **FACET-CONFIDENCE-010** — When confidence settings are initialized, Paid SHALL default intent and technical thresholds to 80/100 each and SHALL permit independently authorized, audited project configuration within 0–100.
- [x] **FACET-CONFIDENCE-011** — When assessing a research issue, Paid SHALL assess clarity and feasibility of its investigation scope rather than require certainty about the implementation answer the investigation seeks.
- [x] **FACET-CONFIDENCE-012** — When an assessment is invalid, fails, or targets superseded evidence, Paid SHALL NOT apply it as a current passing assessment and SHALL expose the unresolved assessment state.
- [x] **FACET-CONFIDENCE-013** — When presenting assessments or constructing builder context, Paid SHALL include both scores and relevant evidence summaries and SHALL distinguish expressed intent, inferred fit and demonstrated feasibility.
  *Tests:* `spec/services/feature_intents/admitted_intent_context_spec.rb`.
  *Code:* `app/services/feature_intents/admitted_intent_context.rb`, `app/services/prompt_assembly/sections/admitted_intent.rb`.
  *Tests:* `spec/services/chat_sessions/build_system_prompt_spec.rb`.
  *Code:* `app/services/chat_sessions/build_system_prompt.rb`.
- [x] **FACET-CONFIDENCE-014** — While displaying Inbox or chat state, Paid SHALL read persisted assessments without making per-entry synchronous LLM calls.
  *Tests:* `spec/services/chat_sessions/build_system_prompt_spec.rb`.
  *Code:* `app/services/chat_sessions/build_system_prompt.rb`.
- [x] **FACET-CONFIDENCE-015** — For confidence-driven features, when project thresholds or facet evidence change after a run starts, Paid SHALL route resulting findings through the confidence-driven delivery policy without using this change alone to pause that run.
  *Tests:* `spec/services/design_amendments/evaluate_impact_spec.rb`, `spec/services/feature_intents/admitted_intent_context_spec.rb`.
  *Code:* `app/services/design_amendments/evaluate_impact.rb`, `app/services/feature_intents/admitted_intent_context.rb`.
- [x] **FACET-CONFIDENCE-016** — When the facet-confidence rubric is evaluated, Paid SHALL provide a frozen, versioned representative corpus covering provisional direction, explicit corrections, repeated agent suggestions, collaborator disagreement, unknown intent with strong technical evidence, strong intent with weak feasibility, research scope, and the 79/80 threshold boundary, with per-case attributable evidence, thresholds, expected outcome bands, and selection rationale retained in the repository.
  *Corpus:* `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`.
  *Code:* `lib/facet_confidence/assessment_corpus_ledger.rb`.
  *Tests:* `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`.
- [x] **FACET-CONFIDENCE-017** — When a corpus assessment run is recorded, Paid SHALL retain the corpus version and content digest, rubric version, model version, and input evidence revision alongside the run outcome, SHALL serialize validation and appending so concurrent events cannot corrupt the ledger, SHALL reject a second run of identical case input as a replay of certainty, and SHALL require a re-run at a correction revision to cite the matching correction event.
  *Code:* `lib/facet_confidence/assessment_corpus_ledger.rb`, `bin/facet-confidence-assessment-evaluation`.
  *Tests:* `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`, `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb`.
- [x] **FACET-CONFIDENCE-018** — When corpus runs and their follow-ups are recorded, Paid SHALL report false readiness, unnecessary clarification, human corrections, assessment cost, and downstream rework per case and in aggregate, and SHALL treat threshold or rubric tuning proposals as unevaluated until these outcome metrics are complete, never justified by throughput alone.
  *Code:* `lib/facet_confidence/assessment_outcome_report.rb`, `bin/facet-confidence-assessment-evaluation`.
  *Evidence:* `assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md` records the operator-measured values; measured runs stay pending operator assessment execution.
  *Tests:* `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`.
- [x] **FACET-CONFIDENCE-019** — When an authorized operator responds to an open feature-decision Inbox item, Paid SHALL persist the explicit statement, actor, and resolution on that existing decision and trigger the established clarity reassessment; it SHALL reject blank, stale, or over-500-character submissions, SHALL NOT truncate a submitted draft, SHALL NOT infer structured choices from decision prose, and SHALL NOT treat the response as feature approval or execution authorization.
  *Tests:* `spec/services/feature_intents/respond_to_decision_spec.rb`, `spec/services/feature_intents/response_drafts_spec.rb`, `spec/requests/feature_intents_spec.rb`, `spec/views/dashboard/inbox_detail_feature_decision_partial_spec.rb`.
  *Code:* `app/services/feature_intents/respond_to_decision.rb`, `app/services/feature_intents/response_drafts.rb`, `app/controllers/feature_intents_controller.rb`, `app/views/dashboard/_inbox_detail_feature_decision.html.erb`.
