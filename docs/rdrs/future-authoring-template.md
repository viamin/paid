# Future RDR Template Overlay

Use this concise overlay with the repository's existing RDR format. Delete
non-applicable prompts; do not add an implementation specification here. The
authoring and transition rules are in the [future RDR contract](future-authoring-contract.md).

```md
# RDR-NNN: <decision title>

## Metadata

- Status: Draft | Proposed | Accepted | Final | Partially Implemented | Implemented | Abandoned | Superseded
- Owner decision: <required for Accepted; person, exact PR/revision, date, conditions>
- Prior RDR impact: <predecessors; overrides/narrowing, or none>
- Related issues and explicit dependencies: <links; `Depends on` / `Blocked by`>

## Problem

<The decision fork and constraints.>

## Recommendation and serious alternatives

<Recommendation and why it wins. List serious rejected alternatives and why.>

## Load-bearing assumptions

| Assumption | Status | Verification method | Concrete evidence or plan | If wrong |
| --- | --- | --- | --- | --- |
| <claim> | Verified | <source, spike, test, peer RDR, etc.> | <durable link> | <decision consequence> |

## Prior-RDR impact

<State compatibility, precedence, and every intentional override.>

## Rollout Guard

<Feature flag/config gate/migration-only/docs-only/none-required rationale,
default state, enablement/rollback, and cleanup condition.>

## Minimum viable validation

<Smallest decisive validation and the evidence it will produce.>

## LID handoff

- HLD: <link and reconciliation>
- Owning LLD: <link>
- EARS: <link>
- Implementation issue prerequisite: <explicit blocking text>

## Finalization record

<Before Final: written answers for contradictions, assumptions, decisive proof,
cross-component/RDR effects, and proportionality; owner-review link.>

## Closeout and post-mortem trigger

<Criterion closeout owner; risk-triggered post-mortem condition, or why optional.>
```

The `LID handoff` and `Finalization record` may be incomplete in Draft,
Proposed, and Accepted states. They must be complete before Final. A pending
load-bearing assumption keeps the record Accepted even when an owner agrees
with the direction.
