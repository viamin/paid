# RDR-070: Facet Confidence and Adaptive Clarification

## Metadata

- **Date**: 2026-09-22
- **Status**: Partially Implemented (see [2026-10-22 Final Acceptance Audit](#2026-10-22-final-acceptance-audit))
- **Type**: Intent modeling and agent judgment
- **Priority**: P1
- **Related RDRs**: [RDR-069](RDR-069-question-centered-chat-exploration.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md)
- **Intent**: [Facet confidence](../intent/facet-confidence/facet-confidence-design.md)
- **Implementation tree**: [Human-centered Inbox delivery plan](human-centered-inbox-implementation.md)
- **Related Issues**: [#4309](https://github.com/viamin/paid/issues/4309) (shared umbrella), [#4323](https://github.com/viamin/paid/issues/4323) (RDR-070 closeout), and [#4573](https://github.com/viamin/paid/issues/4573) (assessment-corpus final-acceptance dependency)

## Implementation Status

The facet/evidence, assessment, adaptive-clarification, explicit-preference,
and scoped-readiness contracts are now implemented with linked tests. The
RDR's versioned representative assessment corpus and its outcome measurement
are delivered (#4573) as
[`docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`](../intent/facet-confidence/assessment-corpus-manifest-v1.yml)
with per-run provenance (corpus/rubric/model/input revisions, replay guard)
and outcome metrics (false readiness, unnecessary clarification, human
corrections, cost, downstream rework) in
[`docs/intent/facet-confidence/assessment-evaluation-2026-10-23/`](../intent/facet-confidence/assessment-evaluation-2026-10-23/README.md);
the operator-executed measured runs remain pending and are recorded as not
established in the outcome worksheet. The umbrella remains open for the
remaining RDR-071 delivery/activation integration. See the 2026-10-22 final
acceptance audit for the criterion-level reconciliation.

### 2026-10-12 Implementation progress audit

This non-closeout progress audit for
[#4309](https://github.com/viamin/paid/issues/4309) records the working-tree
baseline while implementation remains active. It does not apply the closeout
checklist, select a final status, or reconcile the RDR status. The audit
verifies a structural absence rather than a runtime
test failure: no facet or evidence schema, no facet-confidence assessment
pipeline, no adaptive-clarification or preference surface. The umbrella
children that will
deliver RDR-070 are P01 (policy foundation and existing-work
reconciliation), P05 (facets, evidence, and prerequisites), P06
(assessments and explanations), P07 (adaptive clarification and explicit
preferences), P11 (builder context and review policy), and C70 (final closeout
audit). The rollout guard's shadow-mode requirement is automatically
satisfied because no shadow assessment exists; the audit does not
introduce or flip a flag. The PR for this audit uses `Tracks #4309` so
the umbrella stays visibly open for the children. After the implementation
chain finishes or stalls, a final closeout audit can apply the checklist. See
[`audit-report-2026-10-12-rdr-070.md`](audit-report-2026-10-12-rdr-070.md)
for the criterion-by-criterion evidence.

## Problem Statement

An open/resolved question is too coarse to describe evolving understanding.
People may be certain about preserving unfinished answers while still exploring
cross-device behavior. A technically promising implementation is not evidence
that a person wants its behavior. Builders need both forms of information.

## Context

`FeatureIntentDecision` currently records questions and inferred decisions with
an open/resolved status. The repository's Zero Framework Cognition principle
assigns semantic judgment to agents and structural enforcement to code. Extend
existing feature/question links with evidence-backed assessments; do not
introduce hardcoded keyword scoring or counts of repeated phrases.

## Decision

### Facets and two independent scores

A facet is a named aspect of intended behavior, a constraint, or an approach
that a person and agent can discuss separately. It belongs to a feature or a
standalone issue and links to questions, design claims, and dependent issues.

For each candidate direction in a facet, distinguish:

- **Intent certainty (0–100)**: strength and clarity of evidence about the
  human's intended direction.
- **Technical confidence (0–100)**: strength of evidence that the approach is
  feasible for the scoped work.

Candidate scores are independent, not a probability distribution. An
undiscussed preference is unknown, represented separately from a scored
rejection. Null/unknown never passes a readiness threshold. A score of 100 is
an assessment at the top of the scale, not an irreversible decision or proof.

Builders may rank alternatives using explicit intent, inferred fit, and
technical evidence, but must keep those categories distinguishable. Inferring
that an implementation fits established intent does not invent a new preference
or authorize an unsupported product choice.

### Evidence and assessment

Record attributable human statements, corrections, relevant repository facts,
experiment results, and concise answer summaries. Include source references,
actor, time, and the applicable question/design revision. Preserve a summary
of visual context when a temporary diagram is discarded; storing its drawing
history is unnecessary.

An agent, through `agent_harness`, assesses scores with a versioned rubric and
a short explanation citing the evidence. Background jobs compute assessments;
page rendering reads them. Code validates bounds, ownership, required fields,
evidence revision, and concurrency. It does not perform semantic scoring.

The rubric distinguishes tentative exploration, explicit direction, convergent
human answers, contradictions, and clear corrections. Repeated independent
human expressions can reinforce intent; duplicated messages and repeated agent
suggestions cannot. A clear correction supersedes the old direction rather
than being outvoted by its repetition. Conflicting collaborators' statements
remain attributable and trigger clarification; majority counting does not
resolve intent. Technical confidence changes with technical evidence, not
human insistence alone.

Publish both scores and explanations. Users can challenge the interpretation
in chat and receive a revised assessment. Preserve assessment history and
source summaries for accountability without retaining intermediate diagrams.
Reject late assessments for superseded evidence. Failed assessments remain
unavailable rather than manufacturing a passing score.

### Clarification and explicit preferences

The agent selects questions that distinguish plausible directions. For
example, contrasting mouse-oriented and keyboard-oriented interactions can
clarify a feature's interaction facet. Allow both, neither, conditional, and
free-text answers; A-versus-B prompts are probes, not forced binary choices.
Use visual aids only when they help resolve the particular ambiguity.

Durable preferences require an explicit user statement. Store the statement,
owner and scope; allow inspection, correction, and deletion. A contextual
answer applies to its question, not automatically to every future feature.
Do not infer durable preferences from clicks, usage patterns, or agent
interpretations. Ask when the scope of an explicitly stated preference is
unclear. One collaborator's preference does not silently become project policy.

### Readiness interface

The agent identifies the material prerequisite facets of each issue and
explains the mapping. Deterministic code compares every required intent and
technical score with project thresholds, initially **80 and 80**, separately
configurable. No average may hide an insufficient prerequisite. Missing facet
coverage or unknown scores produce an explained not-ready result. An agent
must not omit a material facet merely to make an issue pass.

Assess the issue's own purpose. A research issue can have a sufficiently clear
question and feasible method while the implementation option it investigates
remains uncertain. Implementation must depend on that investigation's result
where it matters. The defaults are provisional policy settings, not calibrated
probabilities or guarantees of successful delivery.

## Alternatives Considered

| Alternative | Decision and rationale |
|---|---|
| Binary final answer | Loses useful degrees of agreement and uncertainty across facets. |
| One feature-wide score | Conceals uncertain prerequisites and blocks unrelated work. |
| Numerical average across facets | Strong scores can conceal a critical unresolved direction. |
| Increment a score per agreement | Repetition and duplicated messages are not independent evidence. |
| Learn preferences from behavior | Explicit preference statements are the only permitted source. |

## Rollout Guard

Assess in shadow mode before scores can release issues. Project operators can
inspect and challenge scores while existing eligibility remains authoritative.
Readiness-driven release is enabled only with the complete RDR-071 delivery
path. Do not silently enroll old features or reinterpret historical answers
as numerically certain. Changing thresholds affects future readiness checks;
it does not pause active runs.

## Implementation and Validation

Implement facets/evidence, assessment with explanations, clarification and
preference handling, then readiness and builder context. Version the rubric
and evaluate representative conversations: unknown intent with a promising
prototype, strong intent with weak feasibility, repeated suggestions, explicit
corrections, collaborator disagreement, and issue-specific research readiness.

Measure inappropriate releases, unnecessary questions, human corrections,
follow-up work and cost alongside delivery time. Verify identical source input
cannot be replayed to inflate certainty. Exact numeric outputs are semantic
assessments; test bounds, evidence fidelity, correction precedence, and release
behavior without asserting arbitrary model-generated numbers.

## Trade-offs

Numerical scores make policy executable but can imply unjustified precision.
Evidence, explanations, unknown states and correction mechanisms are part of
the same feature, not optional observability. Rubric evaluation and assessment
cost are additional work; no score eliminates the need for engineering review.

## 2026-10-22 Final Acceptance Audit

Closeout [#4323](https://github.com/viamin/paid/issues/4323) compared every
RDR-070 acceptance criterion with current source and focused specs. The
evidence supports **Partially Implemented**: core behavior is shipped, and
focused child [#4573](https://github.com/viamin/paid/issues/4573) has since
delivered the versioned assessment corpus and its false-readiness,
clarification, correction, cost, and rework measurement machinery (see
[Implementation Status](#implementation-status)). The operator-executed
measured runs that machinery reports on remain pending, so
[#4323](https://github.com/viamin/paid/issues/4323) is not yet ready for final
acceptance. The audit does not recreate the already-shipped approval policy or
treat closed historical issues as evidence.

The final umbrella audit rechecked the accepted RDR against current models,
services, and focused tests rather than historical issue state. The rollout
guard has progressed from shadow-only assessment to the RDR-071 gated release
path: confidence release remains contingent on complete scoped readiness,
admission, review, publication, and activation-isolation wiring. The default
thresholds remain provisional judgments, not calibrated probabilities, and the
corpus must not tune scores solely to increase throughput. The shadow-mode
guard therefore remains a release-policy constraint; this audit does not
broaden enrollment or change an active run. This closeout tracks
[#4309](https://github.com/viamin/paid/issues/4309); it does not close the
umbrella. The shared audit evidence is also recorded in
[`audit-report-2026-10-22-human-centered-inbox-epic.md`](audit-report-2026-10-22-human-centered-inbox-epic.md).

### 2026-10-26 reference-judgment evidence audit

Issue [#4662](https://github.com/viamin/paid/issues/4662) records the required
human reference-judgment evidence for the frozen corpus. Its
[criterion-level audit](audit-report-2026-10-26-rdr-070.md) confirms the
shipped blinded-labeling, freeze, report, and append-only post-unblinding
correction controls, but records the actual judgment set and compiled report
as pending the authenticated maintainer's session. It does not treat an agent
or a report-less workflow as independent human validation.
