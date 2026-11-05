# RDR-080: Project Delegation After Settled Intent

## Metadata

- **Date**: 2026-11-05
- **Status**: Accepted
- **Type**: Product workflow + authorization + delivery UX
- **Related issues**: #4863; [#4512](https://github.com/viamin/paid/issues/4512)
- **Related RDRs**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md), and [RDR-078](RDR-078-bounded-delivery-phase-authorization.md)
- **Related intent**: `docs/intent/project-delegation/`
- **Implementation status**: Design authority only. It changes no runtime behavior.

## Decision

Add a project-level **delegation posture** to let an owner choose how far Paid
may finish downstream delivery after product intent is settled. The posture is
an input to `Automation::EffectivePolicy`; it is not an approval engine,
feature-readiness policy, or substitute for repository controls. RDR-066
approval-gated intent, RDR-071 confidence-driven readiness, RDR-077 phase
authorization, RDR-078 bounded authorization, CI, security, review, branch
protection, tenant isolation, trust, and budget rules remain independently
authoritative.

The initial owner-facing choices are:

| Posture | Delegated downstream work | Human review still required |
| --- | --- | --- |
| `conservative` (default) | Current behavior only; Paid surfaces downstream decisions in Inbox. | Every existing approval, review, merge, hold, and unresolved-stop decision. |
| `bounded_delivery` | In-scope technical choices, focused follow-up filing, technical-stop recovery, evidence-gated closeout, and cycle analysis/repair. | Settling material intent, all existing repository review/merge gates, and every routed exception. |

The rendered setting must show the effective posture, its source and revision,
the enabled action classes, the phases it can reach, applicable RDR-078 stop
boundaries, and the reviews that remain mandatory. An owner or project admin
may opt a project in. New and existing projects default to `conservative`.

## Intent checkpoint

Before a feature or issue enters delegated downstream work, Paid groups related
material product questions into one reviewable intent checkpoint. For each
group it presents the question, recommendation, alternatives, consequences,
affected scope, and evidence. A human settles, rejects, or amends the group;
the resulting answers are bound to the immutable design and acceptance
revision used for admission. Paid must not ask the same settled question later
merely because it reaches another phase. It may route a new focused decision
only when evidence conflicts with, invalidates, or materially expands that
revision.

Material product behavior, requirements, scope, acceptance criteria, explicit
holds, and unavailable assessment remain human decisions. Technical execution
may choose only among alternatives already bounded by the settled revision.

## Delegated action contract

Every action is evaluated with the current project posture, intent revision,
acceptance revision, evidence revision, phase policy, lineage, and applicable
bounded authorization. The audit record includes actor or system initiator,
policy revision/signature, work identity and lineage, input/output evidence
references, action/result, timestamps, and its routed decision when stopped.

| Action | Limit and required evidence | Stop conditions |
| --- | --- | --- |
| Bounded implementation choice | Choose an implementation detail expressly left open by the settled intent; record the alternatives, selected option, rationale, tests/review evidence, and design/acceptance revisions. | Any product-behavior, scope, acceptance, policy, or risk change; no bounded option; stale revision. |
| Focused follow-up ownership | File or assign one deduplicated issue for a finding, with affected scope, evidence, owner, and explicit dependency on completion where applicable. | Unclear affected scope, conflicting ownership, or a finding that changes active product intent. |
| Technical-stop recovery | Retry, repair, requeue, or request a bounded technical remediation with failure classification, attempted recovery, current checks, and budget evidence. | Explicit hold, exhausted/revoked budget, unrecoverable external failure, or a semantic/product decision. |
| Evidence-gated issue closure | Close only when the current acceptance revision, required tests/checks, review/merge state, dependencies, and open follow-ups all have recorded evidence. | Missing, stale, contradictory, or failed evidence; open material follow-up; unavailable assessment. |
| Cycle analysis and repair | Analyze a repeated delivery stop and apply a bounded repair to the same technical lineage, recording cycle evidence, proposed repair, result, and recurrence count. | Material-risk escalation, changed intent, repeated unsuccessful bounded repair, or a repair outside the pinned lineage. |

The system creates a focused Inbox decision for ambiguity, changed product
scope, conflicting evidence, new material risk, an explicit hold, or an
unavailable assessment. The decision names the smallest affected question,
recommendation, consequences, revision delta, evidence, and next action. It
does not reopen unrelated settled questions.

## One policy contract and revision boundaries

`Automation::EffectivePolicy` is the sole effective-policy contract. Web UI,
REST API, MCP/tool calls, queue admission, dequeue, retry, scheduled
follow-ups, closeout jobs, and cycle-repair jobs call the same decision service
and consume the same projection. No caller may infer delegation from a label,
old approval, queue state, or UI visibility.

A work admission snapshots the effective policy signature and the settled
intent/acceptance/evidence revisions. At every action boundary, including
creation, dequeue, retry, follow-up, repair, and closeout, the service checks
that these are current. A changed project setting affects only new admissions:
it must never silently broaden an in-flight authorization. A running action is
not force-killed, but no next action begins after a failed recheck. Narrowing,
an explicit hold, policy rollback, expiry, or RDR-078's exclusive stop blocks
the next action and records why.

RDR-078 remains the only per-lineage exclusive stop. RDR-077 phase settings
and continuation grants retain their meanings. This posture never refreshes a
stale review, waives a required review, adds merge authority, or authorizes
release, deployment, settings changes, child work, dependencies, or a new PR.

## Rollout Guard and rollback

This design uses the existing default-off `automation_phases` rollout guard
for execution-path integration. A future implementation must add the named,
default-off per-project `project_delegation` enablement surface, evaluate it
through the shared policy, and leave it disabled unless both guards permit the
capability. Rollback sets the project posture to `conservative`, blocks new
delegated boundaries, preserves audit/evidence records, and routes affected
work to a focused Inbox decision. It does not reinterpret or delete history.
No project is enrolled by migration or by an account-level default.

## Measurement and pilot

For each opted-in project, record: human Inbox decisions per completed issue;
median and percentile decision time; completed-issue rate; and the count and
rate of settled decisions later reversed. Measure each against its own
conservative baseline, with reason-coded exclusions and revision-aware joins.

Begin with a small, explicitly opted-in pilot of no more than five projects
using `bounded_delivery`. Review after at least 30 completed issues and 14
days. Do not broaden defaults unless, versus baseline, Inbox decisions per
completed issue decrease by at least 25%, median decision time does not
increase, completion rate does not decline by more than 5 percentage points,
and no material reversal is attributable to delegated work. Any material
reversal, security/tenant/trust breach, or inability to produce metric evidence
pauses expansion and returns affected projects to `conservative` pending human
review.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| A new project approval engine | Rejected: it would conflict with RDR-066/071 and obscure the existing authority boundaries. |
| Always ask downstream technical questions | Rejected: settled intent should reduce routine Inbox work without removing material decisions. |
| Let a setting immediately expand in-flight work | Rejected: consent and evidence must be bound to the policy current at admission. |
| Make automatic closure unconditional | Rejected: closure is a claim about current acceptance evidence, not a workflow terminal state. |

## Follow-on implementation boundaries

1. Add the posture record, policy signature, audit events, and shared effective-policy input behind the named guard.
2. Build intent-checkpoint grouping and immutable revision binding on existing RDR-066/071 records; do not duplicate feature approval or confidence assessment.
3. Add action services and boundary rechecks for all queue, dequeue, retry, follow-up, closeout, and repair paths.
4. Add surface-parity projections for settings, Inbox, API, and MCP, then run the pilot and its review before any default change.

Follow-on implementation issues must cite this accepted RDR and the EARS in
`docs/intent/project-delegation/`.
