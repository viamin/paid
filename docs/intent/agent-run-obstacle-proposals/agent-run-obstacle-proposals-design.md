---
parent: root
prefix: RUN-OBSTACLE
---

# Agent-run obstacle proposals

## Intent

Paid learns from recurring agent-run obstacles without allowing run output,
logs, or comments to become instructions or authority. It reuses the existing
agent-run pattern fingerprint and `RemediationDecision` review record rather
than creating another maintenance engine.

## Current coverage and gap

`QualityFeedbackService` records check output, knowledge evolution samples
`enhance_issue` runs to recommend knowledge additions, and
`AgentRunPatterns::Detect` already groups finished-run failure streaks, rates,
and error clusters into stable fingerprints. The existing maintenance contract
also has repair application and outcome records. Before this segment, those
pieces were disconnected from a reviewable obstacle proposal: detection could
auto-apply a repair, proposals did not retain a bounded scope/validation plan
or uncertainty, dismissed identity could be recreated, and outcome counts did
not establish comparable exposure.

RDR-075 remains a proposed general-maintenance architecture. This segment does
not claim to ship RDR-075 scheduling or broaden its authority; it supplies a
bounded run-obstacle integration that can be reused by that future work.

## Design

The detector performs structural grouping only: tenant-scoped finished runs,
stable fingerprints, bounded sanitized evidence, and exposure counts. A
diagnosis through `agent_harness` classifies the evidence as an
infrastructure/configuration obstacle, an implementation failure, or unknown,
and supplies a suggested correction, validation plan, and uncertainty. The
structured response may cite only supplied evidence pointers. Evidence text is
untrusted data, never instruction.

`RemediationDecision` remains the inspectable proposal and the repair identity.
It stores the affected scope, copied bounded evidence, validation plan,
uncertainty, and exposure/sample counts. The same unresolved fingerprint and
target updates one proposal; a reasoned dismissal remains durable instead of
being replaced. Existing issue filing and repair services remain separately
authorized paths. Pattern detection does not call repair application, create an
execution, or opt an account into automatic remediation.

For an accepted/applied correction, outcome evaluation uses the same goal and
window represented by the proposal. It records before/after failure and
exposure counts. It reports `insufficient_evidence` until the after period has
comparable exposure, and reports improvement/unchanged/regression as observed
recurrence only, not causal proof.

## Boundaries

- Provider-specific execution classification and fixes belong in
  `agent_harness`; Paid receives its structured result and enforces policy.
- No untrusted evidence source can select a target, authorize repair, or cause
  command execution.
- This proposal surface neither changes tenant authorization nor bypasses
  existing approval, review, merge, or repair policies.
