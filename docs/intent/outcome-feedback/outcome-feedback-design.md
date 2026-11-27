---
parent: PAID
prefix: OUTCOME-FEEDBACK
---

# Low-Level Design: Outcome Feedback

**Status:** Finalized, unimplemented delivery contract under
[RDR-082](../../rdrs/RDR-082-optional-outcome-feedback-for-autonomous-assessments.md).
No behavior in this segment is claimed shipped. Current approval-gated and
confidence-driven policies remain authoritative until a separately admitted,
guarded implementation satisfies its claims.

## Purpose and vocabulary

Collect optional human evidence about delivered behavior with minimal effort,
then connect reported mistakes to recorded automated assessments. The domain
terms are defined in [Paid's glossary](../../../CONTEXT.md). Default good is
an operational prior; explicit human feedback and assessment attribution are
distinct evidence.

## Components and flow

1. Feature details and a browsable acceptance-criterion list expose positive
   and negative votes using descriptions of user-visible behavior. A project
   problem-report entry also accepts feedback without a known feature.
2. An authenticated project-authorized submission records its author, target
   scope, known implementation and acceptance revisions, vote, and timestamp.
   Expected and observed behavior are optional. Unknown revisions or feature
   links stay explicitly unknown; they are not silently replaced with latest.
3. Save the vote before optional detail entry or asynchronous investigation.
   Display confirmation and allow change/undo. Preserve a history of changes
   and withdrawals; one author's repeated submissions do not count as
   independent endorsements. A later fix retains the earlier report.
4. Negative feedback schedules a deduplicated investigation when current
   policy, budget, and the rollout guard allow it. Otherwise feedback remains
   saved with an explicit pending/not-started investigation state. A detail
   update can inform the existing investigation without creating parallel runs.
5. Investigation retrieves linked features, criteria, runs, assessment
   snapshots, prompt/model identities, and verification evidence. Semantic
   matching and failure attribution use `agent_harness`; deterministic code
   validates identities, tenant scope, permissions, bounds, and state.
6. Store attribution separately from feedback: assessment references, failure
   type, severity, evidence, and substantiated/disputed/inconclusive outcome.
   Candidate links from a general report are distinguishable from confirmed
   context. Investigation never overwrites a human vote or rewrites an
   assessment's original result.
7. A corrective proposal becomes ordinary deduplicated follow-up work. It
   requires its own applicable admission and authority; a vote supplies none.
8. Reporting separates unexamined defaults, explicit approvals, reported
   problems, and attributed assessment failures. Approved regression cases
   feed evaluation of candidate prompts/models; raw vote counts do not
   directly alter live prompts, quality-gate thresholds, or model selection.

## Persistence and existing integrations

Use durable feedback records and append-only change history as the human source
of truth; do not overload historical blinded labels or manufacture a human
`QualityMetric` for an unexamined implementation. A feedback row records its
tenant/project, author, target, vote, known feature/criterion and revision
identities, submitted time, and current generation. Its history records each
change/withdrawal independently. A criterion is identified by feature,
immutable criterion key, and criterion revision; known implementation/design
revision and assessment/verdict/run links are retained exactly or explicitly
unknown. An external/manual test may be linked to a criterion without
representing a thumbs-up as recorder-owned evidence that the test executed.

Reuse existing quality collectors and reports where their evidence semantics
fit. Existing approval/amendment-based delivery telemetry keeps its original
definition and population; outcome feedback is a separately labeled signal.
Any score projection remains derivable from preserved inputs, carries
its scoring version, and avoids multiplying one report into independent
penalties for every related assessment. Missing evidence or failed
investigation does not restore a positive score or hide the reported problem.

## Policy and migration boundary

The default-off project flag proposed by RDR-082 gates collection and new
investigation starts. UI and agent/API actions have equivalent authorization
and feedback semantics. Feedback content is untrusted; use the existing
trusted-input boundary for agent processing and escaped/sanitized rendering.
Tenant-scoped reads/writes and job context remain mandatory.

The migration inventory maps each old evaluation task/dependency to retained
benchmark work, superseded workflow, reusable infrastructure, or unrelated
work. Autonomous projects no longer require historical comparison once the
replacement is activated. Approval-gated features keep their original guards.
Existing evaluations and votes survive disabling the new collection surface.

## Decisions and alternatives

| Decision | Alternative | Reason |
| --- | --- | --- |
| Save a vote before requesting details | Require a full bug report | Preserve one-click usefulness and allow incomplete but meaningful negative feedback. |
| Keep attribution separate from feedback | Let investigation rewrite the vote | Preserve user experience evidence even when Paid disputes its explanation. |
| Bind feedback to known versions and scope | Treat feature approval as timeless | Prevent old approval from endorsing later implementations or unrelated criteria. |
| Preserve optional benchmark capability | Maintain mandatory comparison in parallel | Keep controlled evaluation without duplicate operational bureaucracy. |

## Implementation boundaries

An investigation's sole initial goal is to determine whether a retained
negative report can be substantiated as an assessment failure. One open
investigation is deduplicated per feedback generation and target/revision
identity. Detail changes append feedback history and update that investigation
context; they do not create parallel work. New corrective work is separately
deduplicated and admitted.

Feedback text, provider text, and agent-proposed links are untrusted. Code
enforces tenant/project identity, authorization, rollout guard, budget,
identity shape, and state. `agent_harness` performs only bounded semantic
matching and attribution. Scoring consumers and weights require a later,
versioned decision; the first release keeps separate evidence classes without
numeric weighting.
