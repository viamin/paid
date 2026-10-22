# RDR-070 Assessment Audit — 2026-10-12

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Assessment issue**: [#4323](https://github.com/viamin/paid/issues/4323)
  (open; it tracks, and does not close, [#4309](https://github.com/viamin/paid/issues/4309))
- **Result**: **Implementation closeout is not yet eligible. RDR-070 remains
  Accepted.** None of the closeout checklist's terminal statuses is accurate:
  the RDR is neither implemented, partially implemented, superseded, nor
  abandoned. Its active, focused implementation work remains open.

This bounded audit uses RDR-070's Decision and Implementation and Validation
sections plus `docs/intent/facet-confidence/` as the current intent. It checks
current code and tests rather than treating closed issues as proof. The
historical approval-gated contracts cited by the implementation plan were
reconciled as reusable foundations only; they are not facet-confidence
implementation evidence.

## Evidence by acceptance area

| RDR-070 requirement | Result | Code/test evidence and remaining owner |
| --- | --- | --- |
| Separate bounded intent/technical scores, explicit unknown, attributable evidence, material mapping | Gap | `FeatureIntentDecision` ([`app/models/feature_intent_decision.rb:9`](../../app/models/feature_intent_decision.rb#L9)) only stores an open/resolved question or inferred decision; the migration `db/migrate/20260917072615_create_feature_intent_decisions.rb` has no score, evidence revision, source, provenance, facet, or issue-prerequisite fields. Its existing behavior is covered by [`spec/models/feature_intent_decision_spec.rb:20`](../../spec/models/feature_intent_decision_spec.rb#L20), not by a facet-confidence spec. No `Facet`, `Assessment`, or `Preference` model/service/spec exists. Focused owner: [#4314](https://github.com/viamin/paid/issues/4314) (`FACET-CONFIDENCE-001`, `002`, `008`). |
| Agent-harness assessment with rubric/evidence revisions, correction precedence, duplicate/repeated-agent resistance, collaborator clarification, challenge/reassessment, stale/failed output safety, read-only rendering | Gap | There is no facet assessment job, rubric, agent-harness request, assessment history, or assessment presentation. [`app/services/clarifying_questions/choice_answers.rb:76`](../../app/services/clarifying_questions/choice_answers.rb#L76) validates existing final choice answers, with parser tests at [`spec/services/clarifying_questions/choice_answers_spec.rb:36`](../../spec/services/clarifying_questions/choice_answers_spec.rb#L36), but does not assess semantic confidence or persist correction provenance. Focused owner: [#4315](https://github.com/viamin/paid/issues/4315) (`FACET-CONFIDENCE-002`–`005`, `012`–`014`). |
| Discriminating questions and durable explicit preferences with provenance, authorization, correction/deletion, and non-inference from interactions | Gap | Existing clarifying-question choices are final-answer validation, not adaptive facet questions. No durable product-preference record, scope/provenance enforcement, or preference inspection/correction/deletion surface exists. Focused owner: [#4316](https://github.com/viamin/paid/issues/4316) (`FACET-CONFIDENCE-006`, `007`). |
| Per-facet readiness: known scores independently meet configurable 80/80, unknown/empty mapping fails, no average, research scope is distinct | Gap | [`app/services/feature_intents/approval_readiness.rb:26`](../../app/services/feature_intents/approval_readiness.rb#L26) enforces the separate approval-gated RDR-066 policy; its readiness cases are tested at [`spec/services/feature_intents/approval_readiness_spec.rb:9`](../../spec/services/feature_intents/approval_readiness_spec.rb#L9). It has no facet mapping, separate confidence thresholds, assessment revision, or shadow-mode readiness result. No 79/80 readiness specs exist. Focused owner: [#4318](https://github.com/viamin/paid/issues/4318) (`FACET-CONFIDENCE-008`–`012`). |
| Versioned representative assessment corpus and measurements of false readiness, unnecessary clarification, corrections, cost, and rework | Gap | No versioned facet-confidence corpus or reporting artifact exists. This audit cannot report fabricated delivery metrics. #4315 owns rubric/corpus inputs and #4318 owns readiness outcomes; the closeout must run and record the corpus only after those behaviors ship. |

## Reused but insufficient foundations

`FeatureIntentDecision`, `ClarifyingQuestions::SubmitAnswers`, and
`ClarifyingQuestions::ChoiceAnswers` are real, tested approval-gated/final-answer
primitives. They cannot satisfy RDR-070 by implication: none retains
independent confidence axes, unknown state, source revision, assessment rubric,
correction supersession, durable explicit preference provenance, or a
confidence readiness decision. Reusing them must preserve their existing
approval-gated policy rather than recreating or relabeling it as
confidence-driven behavior.

## Required gaps and dependencies

No duplicate child issue was filed. Each unmet requirement already has one
focused, open owner under [#4309](https://github.com/viamin/paid/issues/4309):

- [#4314](https://github.com/viamin/paid/issues/4314): facets, attributable
  evidence, candidate directions, and prerequisite mapping.
- [#4315](https://github.com/viamin/paid/issues/4315): versioned assessment,
  explanation, correction/reassessment, and corpus.
- [#4316](https://github.com/viamin/paid/issues/4316): adaptive clarification
  and explicit preference lifecycle.
- [#4318](https://github.com/viamin/paid/issues/4318): deterministic scoped
  readiness and authorized 80/80 configuration.

Issue #4323 already explicitly depends on #4316 and #4318. The audit records
\#4314 and #4315 as required upstream implementation gaps; its final closeout
must not claim implementation until all four owners have shipped and supplied
running evidence. It keeps non-closing `Tracks #4309` language; only the
umbrella's final acceptance audit may close #4309.

## 80/80 policy and rollout guard

The intended 80/80 defaults are provisional policy judgments, not calibrated
probabilities, success guarantees, or a throughput target. There are no scores
to tune today. The eventual corpus must report false readiness, unnecessary
clarification, human corrections, cost, rework, and delivery time together;
raising scores simply to release more work would violate RDR-070.

RDR-070's rollout guard requires shadow-mode assessment before scores can
release issues. **Disposition: pending and preserved.** No facet assessment or
confidence-driven release path is shipped, so no runtime behavior bypasses the
guard. #4318 must keep assessments non-authoritative until the complete
RDR-071 admission/review/completion wiring is available.

## Verification

The audit's absence findings were confirmed by code inspection and the EARS
status ledger: every `FACET-CONFIDENCE-001` through `015` entry remains `[ ]`
in `docs/intent/facet-confidence/facet-confidence-specs.md`. The no-database
choice-answer foundation spec passed with 29 examples, and RuboCop passed with
3,863 files inspected and no offenses. `bin/coherence-check.mjs` completed
with the expected facet-confidence and confidence-delivery `[ ]` gaps; it
reported no arrow-reference errors. Database preparation could not reach the
configured PostgreSQL service in this environment, so this audit must not
report database-backed validation as passing. These checks validate that
documenting the current status does not regress shipped behavior, not
nonexistent facet-confidence behavior.
