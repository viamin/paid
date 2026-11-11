# Future RDR Authoring Contract

This is the Paid-owned authoring contract for RDRs created after this document
is accepted. It is a decision-and-evidence workflow, not a second implementation
specification. The [LID arrow](../lid/workflow.md) remains the owner of
implementation intent: HLD → LLD → EARS → tests → code. Do not bulk-retrofit
historical records to this format.

Use the concise [template overlay](future-authoring-template.md) with a new
RDR. Keep it proportionate: link to the HLD, owning LLD, and EARS claims rather
than reproducing their component design or observable requirements.

## Authority and status transitions

An RDR recommends a decision; it never independently authorizes runtime work.
The following statuses are intentionally non-overlapping.

| Status | Meaning | Entry evidence | What it does not authorize |
| --- | --- | --- | --- |
| **Draft** | Research or recommendation is being formed and may change. | A record exists. | An implementation issue, runtime work, or an owner decision. |
| **Proposed** | A reviewable recommendation is ready for owner decision. | The minimal decision/evidence home is complete enough to review, including serious alternatives, assumptions, prior-RDR impact, rollout guard, and minimum viable validation. | Acceptance or implementation. A merged draft is still not acceptance. |
| **Accepted** | The owner accepted the recommendation in this exact RDR revision, but its implementation intent is not yet eligible. | An explicit owner decision identifying the reviewed PR/revision and any stated conditions. | Runtime work. A filed issue is planning only until its concrete LID prerequisite is met. |
| **Final** | The accepted decision is locked and has completed its LID handoff; delivery may begin subject to ordinary Paid/repository controls. | The finalization record, reconciled HLD/LLD/EARS links, resolved load-bearing assumptions, and an implementation issue whose explicit prerequisite names those artifacts. | Bypassing rollout guards, dependencies, review, or any other admission control. |
| **Partially Implemented** | A Final RDR has shipped and criterion-level closeout shows some, but not all, required criteria complete. | A closeout record maps every criterion to shipped evidence or a focused remaining issue/dependency. | Calling the decision fully delivered. |
| **Implemented** | Criterion-level closeout shows every required criterion shipped and the rollout guard has been reconciled. | A closeout record with inspectable code/test/external evidence for every criterion and no required gap. | Claiming a later operational post-mortem occurred. |

The author moves **Draft → Proposed** after proportionate review makes the
recommendation legible. The owner moves **Proposed → Accepted** only by an
explicit decision on the exact revision; merging, filing an issue, or approving
an earlier revision is insufficient. An owner may accept a recommendation with
an unresolved assumption, but it remains **Accepted**, not Final, until the
assumption is resolved. **Accepted → Final** requires the completed handoff
below. A material recommendation or evidence change returns the record to
Draft/Proposed and invalidates prior acceptance until the owner accepts the
new exact revision.

Final means *eligible to start the ordinary delivery process*, not that a
runner may bypass it. Future implementation issues may be filed at any time,
but must state a concrete prerequisite such as “Blocked by Final RDR-NNN and
merged `SEGMENT-NNN` EARS claims”; an RDR draft alone never advances runtime
work. Preserve explicit `Depends on #123` / `Blocked by owner/repo#123`
dependency declarations and the RDR's rollout guard.

## Minimal decision and evidence home

Each future RDR contains only the material needed to choose and steward the
decision:

- **Problem and recommendation** — the decision fork, proposed direction, and
  why it is preferable.
- **Serious alternatives** — realistic alternatives and their rejection reason.
- **Load-bearing assumptions** — each has a status, verification method,
  concrete evidence pointer (or an executable verification plan), and the
  consequence if wrong. “Pending” is an honest status, not evidence.
- **Prior-RDR impact** — predecessors, affected contracts, and an explicit
  override/narrowing statement where applicable.
- **Rollout guard** — use the repository's existing feature-flag, config-gate,
  migration-only, docs-only, or justified-none convention.
- **Minimum viable validation** — the smallest decisive validation that proves
  the recommendation in the scope it claims.

The owning LLD contains components, interfaces, data flow, and implementation
choices. EARS contains observable, testable behavior. The RDR links to those
normative contracts after they exist; it does not copy them. Ordinary facts may
be cited in prose, but only assumptions whose failure would change the
recommendation need the structured assumption record.

## LID handoff and worked example

After acceptance, walk the arrow before implementation. Reconcile the decision
with the HLD, then write or update the owning LLD and EARS claims. Their normal
LID review is separate from, and downstream of, the owner's RDR acceptance.
Only then may Final be recorded and an implementation issue become eligible.

RDR-078 illustrates the boundary without duplicating contracts:

| RDR concern | Owner after handoff | Link, not duplication |
| --- | --- | --- |
| Why a bounded authorization is needed; choice against broader delegation | HLD's human-final-say/authority approach | [RDR-078](RDR-078-bounded-delivery-phase-authorization.md) supplies the decision evidence; the HLD owns the platform boundary. |
| Lifecycle, scope invalidation, effective-policy composition, and surface parity | `bounded-phase-authorization` LLD | [LLD](../intent/bounded-phase-authorization/bounded-phase-authorization-design.md) owns component design. |
| Fail-closed admission, consent, recheck, and no implicit release behavior | `bounded-phase-authorization` EARS | [EARS claims](../intent/bounded-phase-authorization/bounded-phase-authorization-specs.md) own observable requirements and test traceability. |
| Selected endpoint, rollout/merge boundary, and delivery slices | RDR-078 plus the implementation issue tree | The RDR keeps the decision and guard; issues carry explicit prerequisites and dependencies. |

If an RDR-078-style load-bearing assumption (for example, a scope-assessment
contract) remains pending, record its verification method, evidence plan, and
failure consequence. The owner may accept the direction, but it stays Accepted;
no Final handoff or runtime implementation starts until evidence resolves it or
the owner revises the recommendation and accepts that revision.

## Written finalization record

Before setting an RDR to Final, add a short written record to the RDR or its
review PR. Answer each item with concrete links/evidence, not a checkbox:

1. **Contradictions:** What conflicts were found among research, the
   recommendation, prior RDRs, and the HLD/LLD direction, and how were they
   resolved?
2. **Assumptions:** For each load-bearing assumption, do status, method,
   evidence, and consequence agree? List none only when none are load-bearing.
3. **Decisive proof in scope:** What minimum viable validation proves the
   recommendation, and why does it exercise the claimed scope?
4. **Cross-component/RDR effects:** Which components or records change? For a
   cross-RDR change, include explicit pairwise reconciliation for each affected
   record — for example, RDR-077/RDR-078 — saying which contract governs,
   whether either is narrowed or overridden, and where the LLD owner lives.
5. **Proportionality:** Why is this review depth appropriate to blast radius,
   irreversibility, security/authority impact, and contract count? State what
   was deliberately left to the LLD/EARS rather than expanding the RDR.

Review depth scales with risk. A small, reversible, single-component decision
may have one author plus owner review and concise evidence. Cross-component,
security/authority, irreversible, or cross-RDR decisions require relevant
component owners and explicit reconciliation. Structural checks can report
links, headings, and traceability; they cannot certify that these answers are
true or that the recommendation is semantically sound. Owner review of this
exact process revision is required before automation enforces it.

## Closeout and post-mortem are different

Run [criterion-level implementation closeout](closeout-checklist.md) whenever
an RDR is claimed Partially Implemented or Implemented. It is a before/after
check against the RDR criteria, shipped behavior, tests, external evidence,
remaining gaps, dependencies, and rollout guard. It determines the delivery
status.

A plan-versus-reality post-mortem happens later, after meaningful use, to
evaluate whether the recommendation and rollout behaved as expected. It is
required for large/foundational decisions and any decision with material
authority, security, irreversible-data, or cross-component effects; schedule
its trigger in the Final record (for example, a duration, volume, or rollout
milestone). It is optional for a small or mid decision with no material
surprise, but authors may record a brief outcome. A post-mortem does not
retroactively replace closeout evidence; discoveries create a follow-up or a
new/revised RDR.

## Upstream method and deliberate Paid differences

The current [upstream RDR README](https://github.com/cwensel/rdr/blob/main/README.md)
and [template](https://github.com/cwensel/rdr/blob/main/TEMPLATE.md) informed
this contract's iterative drafting, serious alternatives, critical-assumption
evidence, written finalization gate, proportional review, and post-mortem
distinction. This document is Paid-authored prose, not copied template text;
the upstream project is MIT-licensed and its attribution remains at those
sources.

Paid deliberately differs by keeping the RDR as a proportionate decision home,
not a full implementation specification; assigning implementation design and
observable behavior to the LID HLD/LLD/EARS arrow; adding **Proposed** and
**Accepted** to separate owner decision from implementation eligibility; and
requiring existing rollout-guard and explicit-dependency conventions. Paid
also treats post-mortem timing as risk-triggered rather than making it a
universal prerequisite to criterion-level implementation closeout.
