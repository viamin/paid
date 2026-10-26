# RDR-070 Closeout Evidence Audit — 2026-10-26

## Scope and outcome

This audit covers the reference-judgment evidence requested by
[#4662](https://github.com/viamin/paid/issues/4662) for RDR-070 closeout
[#4323](https://github.com/viamin/paid/issues/4323). It is not a completion
claim for either issue or the shared umbrella.

**Outcome: blocked on the authenticated maintainer and one shipped-flow gap.**
The frozen `facet-confidence-corpus-v1` and the closeout-evaluation entry
point are present. No independent human reference-judgment set was found or
created by this audit. An agent must not create that evidence or represent an
agent-authored label as a maintainer judgment.

## Verified shipped behavior

| Required behavior | Evidence | Result |
| --- | --- | --- |
| Inbox packet exposes the originating item, frozen corpus digest, rubric, model, input revisions, and closeout blockers | `FacetConfidence::CloseoutEvaluationPacket`; `FACET-CONFIDENCE-020` | Present |
| Start/Resume pins one evaluation to the originating closeout and corpus digest | `FacetConfidence::CloseoutEvaluation::Start`; unique `(issue_id, corpus_digest)` index | Present |
| Only the authenticated operator who started an evaluation can record or freeze blinded judgments | `FacetConfidenceEvaluationPolicy`; `RecordLabel`; `FreezeLabels` | Present |
| Pre-freeze screen hides case shape, selection rationale, and frozen expectations | `FacetConfidence::CloseoutEvaluation::CaseView`; `FACET-CONFIDENCE-021` | Present |
| Freeze requires a labeled judgment for every corpus case and retains a comparison report with divergences and citation compliance | `FreezeLabels`; `CompileReport` | Present |
| Reference judgments remain policy assessments and do not change 80/80 or enable delivery | `CompileReport` policy statement; RDR-070 rollout guard | Present |
| A post-unblinding correction preserves the original label and records a reasoned revision | No facet-confidence revision fields, service, route, or UI were found | Gap |

## Human prerequisite

The authenticated maintainer must start or resume the evaluation from #4323's
Inbox item and record one independent blinded judgment for every corpus case:
verdict, intent band, technical band, readiness, exactly one evidence
reference, and a reason. They must then freeze the set. Only that action can
produce the required human evidence and the attached compiled report.

The agent performed no start, label, freeze, or correction action and did not
inspect frozen expectations through a labeling session. Accordingly, this
audit cannot claim a judge identity, frozen timestamp, case coverage, report,
divergence result, or citation-compliance result.

## Required follow-up before closeout evidence is complete

1. Add the missing post-unblinding correction path. It must retain the
   original frozen judgment, capture the corrected judgment, authenticated
   maintainer, timestamp, and a separate reason, and keep comparisons against
   the original label.
2. The authenticated maintainer records and freezes all eight judgments in
   their own session.
3. Attach the persisted compiled report to #4323 and replace the
   not-established entries in this audit with its provenance, divergences, and
   citation-compliance evidence.

## Rollout guard

RDR-070 remains in shadow assessment. This evidence work does not release
issues, change the separate 80/80 defaults, or enable the RDR-071 delivery
path. The labels are policy assessments, not calibrated probabilities.

## Verification and environment note

`bundle install` completed. `yarn install --frozen-lockfile` completed after
clearing a corrupt local Yarn cache. Database preparation could not run: the
provided service was unavailable, and the configured PostgreSQL role was
rejected as `SUPERUSER`/`BYPASSRLS` by the application's runtime-role guard.
No migration was hand-authored and no safety guard was bypassed. The focused
test suite and lint therefore remain unrun in this environment.
