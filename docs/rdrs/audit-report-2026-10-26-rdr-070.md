# RDR-070 Closeout Evaluation Evidence Audit — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Evidence issue**: [#4662](https://github.com/viamin/paid/issues/4662)
- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323)
- **Result**: **Reference-judgment evidence is not yet established.** The
  shipped evaluation flow is ready for an authenticated maintainer, but no
  agent-authored judgment, frozen set, or compiled report is claimed here.

This is a current-source audit, not evidence inferred from closed child issues.
It records the human prerequisite precisely: the authenticated maintainer must
start or resume the evaluation from #4323's Inbox item and make every blinded
judgment in their own session.

## Criterion assessment

| Criterion | Assessment | Evidence / remaining action |
| --- | --- | --- |
| Inbox packet and Start/Resume show pinned corpus provenance | Satisfied in shipped behavior | `FacetConfidence::CloseoutEvaluationPacket` supplies work item, source revision, digest, rubric, model, and input revisions; `Start` persists one evaluation per closeout/digest. The current corpus is `facet-confidence-corpus-v1`, SHA-256 `126b30c6b4796466f3057f78d0bedbb901e6fdb942ca14cafb7549ac396ecc0c`, rubric `facet-confidence-v1`, model `claude-sonnet-4-6`. |
| One blinded reference judgment per case, then freeze | Awaiting human evidence | The labeling and freeze flow requires all eight cases to be labeled and keeps frozen expectations hidden until freeze. A maintainer must record the verdict, both bands, derived readiness, cited case evidence, and reason for each case. |
| Auditable human identity | Awaiting human evidence | The evaluation's `created_by` and every label's `recorded_by` are persisted and services reject a different actor. The actual record must come from the maintainer’s authenticated session; no alias, bot, or agent identity is acceptable. |
| Preserve a correction after unblinding | Satisfied in shipped behavior; needs migration-backed verification | `ReviseLabel` appends one complete, reasoned revision with actor and time while retaining the original blinded fields and their report comparison. |
| Compiled report attached to the closeout | Awaiting human evidence | Freeze compiles judgments, frozen expectations, divergences, and citation compliance onto the persisted evaluation, which the originating Inbox item links back to. No report exists until the maintainer freezes the set. |
| Policy and rollout constraints | Satisfied | The report and corpus state that judgments are policy assessments, not calibrated probabilities; they neither change the separate 80/80 defaults nor enable delivery. RDR-070 remains shadow-mode constrained pending the complete RDR-071 delivery path. |

## Verification and limits

Focused service and request specs cover the existing packet, labeling, freeze,
report, identity, and blinding behavior. This change adds coverage for
append-only corrections and report separation under `FACET-CONFIDENCE-021`.
The available PostgreSQL connection uses an unsafe superuser/BYPASSRLS role,
so Rails correctly refuses migration and test execution; no role guard was
bypassed and no database-backed pass is claimed. The maintainer must run the
migration and focused checks with the configured application role before using
the correction path.

The human prerequisite remains the sole blocker for #4662. Completing it
supplies evidence to #4323; it does not close #4323 or the #4309 umbrella.
