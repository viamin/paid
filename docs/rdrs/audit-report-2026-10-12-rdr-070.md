# RDR-070 Implementation Progress Audit — 2026-10-12

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Audit date**: 2026-10-12
- **Umbrella issue**: [#4309](https://github.com/viamin/paid/issues/4309) (epic — open)
- **Implementation work**: P01, P05, P06, P07, P11, C70
- **Progress finding**: No RDR-070 acceptance criterion has
  shipped code or test evidence. The facets, evidence, assessment pipeline,
  clarification, explicit-preference persistence, and readiness handoff all
  remain in their current non-feature state. The audit records the unimplemented
  scope and files it against the umbrella's open children; the umbrella
  remains open for the implementation work that will deliver it.

This is a non-closeout progress audit. The implementation chain is active, so
it does not apply the [RDR Closeout Checklist](closeout-checklist.md), select
a final status, or reconcile the RDR status. It records the current baseline
for the implementation work that remains.

## Acceptance evidence

| RDR-070 criterion | Result | Code and test evidence |
| --- | --- | --- |
| Facets and candidate directions on a feature/issue | **Gap** | No `Facet`, `FacetCandidate`, or related model exists in `app/models`. `FeatureIntent` and `FeatureIntentDecision` carry open/resolved status only. |
| Separable intent and technical confidence scores on a 0–100 scale with explicit unknown | **Gap** | No score columns, no `unknown` state, no bounds validation. |
| Evidence records with attribution, source, time, design revision, supersession, and textual context | **Gap** | No evidence table or evidence-attribution service exists. |
| Agent-produced assessments with evidence references, rubric/model version, and concise explanation via `agent_harness` | **Gap** | No `Assessment` model, no `agent_harness`-driven assessment job, no assessment-rubric artifact exists. |
| Explicit corrections supersede superseded statements; collaborator disagreement triggers clarification | **Gap** | No evidence tracking exists. |
| Repeated agent suggestions and incidental interactions do not drive intent certainty | **Gap** | No assessment pipeline exists. |
| Chat-based challenge revises affected facets with visible explanation | **Gap** | No challenge flow exists. |
| Adaptive clarifying questions (A/B, both/neither, conditional, free-text) | **Gap** | `ClarifyingQuestions::Choices` and the chat-composed answer validator (`app/services/clarifying_questions/choice_answers.rb`) handle the existing widget choices; no comparative-context aid, no A/B instrumentation, no selection-vs-preview discrimination exists. |
| Explicit-preference persistence with provenance and authorized inspection/correction/deletion | **Gap** | No preference record type, no preference service, no `Settings::User` / `Settings::Project` exposure for facet-relevant preferences. Clicks and assessment inference cannot drive interpretation because the facets do not exist. |
| Issue prerequisite mapping with rationale and coverage assessment; empty unassessed mapping fails visibly | **Gap** | No prerequisite mapping service exists. `FeatureIntents::ApprovalReadiness` (`app/services/feature_intents/approval_readiness.rb`) is the existing approval-gated readiness gate and does not score facets. |
| Initial readiness requires every material facet's intent and technical score to meet the project threshold | **Gap** | No threshold-based readiness service exists. |
| Default intent and technical thresholds of 80/100; authorized, audited project configuration within 0–100 | **Gap** | No thresholds table or settings exposure exists. |
| Research-issue assessment scoped to investigation clarity/feasibility | **Gap** | No research-scoped assessment exists. |
| Invalid, failed, and superseded-revision assessments never pass and the unresolved state is visible | **Gap** | No assessment pipeline exists. |
| Builder context includes both scores, evidence summaries, and distinguishes expressed intent from inferred fit from demonstrated feasibility | **Gap** | No assessment context assembly exists. |
| Inbox/chat state reads persisted assessments without per-entry synchronous LLM calls | **Gap** | No assessment read path exists. |
| Confidence-driven threshold/evidence change after a run starts does not pause that run | **Gap** | No confidence-driven policy dispatch exists. |

## EARS reconciliation

`docs/intent/facet-confidence/facet-confidence-specs.md` lists 15 claims,
all marked `[ ]` planned and unimplemented. No claim mapping
`FACET-CONFIDENCE-001` through `FACET-CONFIDENCE-015` is referenced from
`app/` or `spec/` via `@spec` annotations. The `prefix: FACET-CONFIDENCE`
front matter remains accurate; the design doc's "Status: planned, not
implemented" caveat in
[`docs/intent/facet-confidence/facet-confidence-design.md`](../intent/facet-confidence/facet-confidence-design.md)
is upheld.

## Current status

- `docs/rdrs/RDR-070-facet-confidence-and-clarification.md`: status remains
  `Accepted`, which denotes an accepted decision whose implementation has not
  started. This progress audit does not perform closeout status reconciliation.
- `docs/rdrs/README.md`: RDR-070 row status remains `Accepted`.
- `docs/arrows/index.yaml`: the `facet-confidence` segment status stays
  `MAPPED`; no code added, audited 2026-10-12.

## Rollout guard preserved

RDR-070's rollout guard requires shadow-mode assessment before scores can
release issues, and forbids silently enrolling old features or
reinterpreting historical answers as numerically certain. The current
working tree has neither shadow assessment nor readiness enforcement; the
guard is therefore automatically satisfied (nothing to gate). The audit
does not introduce or flip a flag.

## Remaining implementation work and deployment prerequisites

The remaining work is the entire RDR-070 acceptance scope. The umbrella
children that will deliver it are P01 (policy foundation and existing-work
reconciliation), P05 (facets, evidence, and prerequisites), P06
(assessments and explanations), P07 (adaptive clarification and explicit
preferences), P11 (builder context and review policy), and C70 (final closeout
audit). The umbrella issue #4309 remains open while that implementation work
is active. A final closeout audit must run only after the implementation chain
finishes or stalls.

## Verification record

The audit environment ran `bundle install`, `bin/rails db:prepare`
(PostgreSQL via `DATABASE_URL`), and `bin/coherence-check.mjs`. No new code
or test was written, so no new regression risk was introduced. The audit
checks `db/schema.rb` for facet/score/preference tables and finds none;
checks `app/models`, `app/services`, and `app/policies` for facet or
assessment code and finds none; checks `spec/` for facet or assessment
specs and finds none. The result is a structural absence rather than a
runtime test failure.
