# RDR-070 Reference-Judgment Evidence Audit — 2026-10-26

## Scope and conclusion

This audit covers issue [#4662](https://github.com/viamin/paid/issues/4662),
the reference-judgment evidence required by RDR-070 closeout
[#4323](https://github.com/viamin/paid/issues/4323). It is evidence for the
closeout only; it neither closes #4323 nor the shared umbrella.

**Conclusion: blocked on authenticated human judgment.** The shipped
Start/Resume, blinded-labeling, freeze, and report flow is present for the
frozen corpus, but this audit found no recorded human reference-judgment set
for `facet-confidence-corpus-v1`. An agent must not supply those judgments or
represent them as independent human validation.

## Frozen evaluation packet

| Field | Recorded value |
| --- | --- |
| Corpus version | `facet-confidence-corpus-v1` |
| Corpus digest | `126b30c6b4796466f3057f78d0bedbb901e6fdb942ca14cafb7549ac396ecc0c` |
| Rubric version | `facet-confidence-v1` |
| Model version | `claude-sonnet-4-6` |
| Corpus cases | 8 |
| Input evidence revisions | `2, 3, 4, 3, 2, 2, 2, 2` |

The authenticated maintainer must start or resume the evaluation from the
originating closeout's Inbox item. That packet shows its own current source
revision, the identities above, and any closeout blockers; this audit does not
create an evaluation or substitute a session identity.

## Criterion-level assessment

| Criterion | Evidence reviewed | Result |
| --- | --- | --- |
| Packet displays frozen corpus digest, rubric, model, input revisions, and Start/Resume | `FacetConfidence::CloseoutEvaluationPacket`, `FacetConfidence::CloseoutEvaluation::Start`, and `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb` | Shipped; awaiting maintainer use |
| One blinded judgment per case before expectations are visible, then freeze | `RecordLabel`, `FreezeLabels`, and their focused specs | Shipped; no human labels recorded |
| Authenticated maintainer is the sole auditable judge | `FacetConfidenceEvaluation.created_by`, `FacetConfidenceEvaluationLabel.recorded_by`, and sole-judge guards in `RecordLabel` and `FreezeLabels` | Shipped; awaiting maintainer session |
| Original labels survive a post-unblinding correction with its own reason | Frozen labels reject further writes; labels are updated in place while open, and no correction-revision record exists | **Gap** |
| Compiled report is attached to the closeout and compares judgments, divergences, and citation compliance | `CompileReport` is invoked only after a frozen reference set; no human reference set or generated report exists | Blocked on human labels |
| 80/80 defaults remain policy assessments; delivery remains disabled | RDR-070 rollout guard and `CompileReport` policy statement | Preserved |

## Required human action

The authenticated maintainer must independently record all eight judgments in
their own session, with each case's verdict, intent band, technical band,
readiness, one permitted evidence reference, and reason. They must freeze the
reference set before viewing frozen expectations. The resulting compiled report
can then be attached from the originating Inbox item and this audit refreshed
with its provenance and measured divergences.

Before the issue can close, the post-unblinding correction gap also requires a
revision-preserving implementation: retain the original frozen judgment,
append the corrected judgment with a correction reason and actor, and keep the
original set as the scoring baseline.

## Policy and rollout guard

Reference judgments are policy assessments, not calibrated probabilities. This
audit makes no threshold or rubric change, preserves the 80/80 defaults, does
not enable delivery, and does not alter an active run.
