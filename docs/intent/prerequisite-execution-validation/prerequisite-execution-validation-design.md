---
parent: operator-inbox
prefix: PREREQUISITE-EXECUTION
---

# Low-Level Design: Prerequisite Execution Validation

## Purpose

An Inbox prerequisite can require live technical evidence that cannot be
inferred from an operator's workstation. This component starts one bounded,
report-only `AgentRun` from the originating partial-closeout item so the
normal isolated execution lifecycle can collect that evidence.

## Design

`Issues::RequestPrerequisiteExecutionValidation` records the requested
artifact contract, runner/backend capability snapshot, and sidecar-rollout
authorization in the queued run's immutable execution context. It asks the
runner interface for capabilities; it never treats the absence of a local
Docker client or socket as a statement about Paid's execution backends.

The run has the existing `analyze_issue` goal and a fixed read-only prompt. It
uses the ordinary AgentRun queue, marketplace attachment, provisioning,
execution, cancellation, retry, and cleanup paths. It cannot create a PR,
close the source issue, mount a Docker socket, or expose a host shell. Native
tools execute only through `execute_in_execution_environment`; a sidecar is
used only when attached through the existing marketplace flow and its scoped
rollout flag remains authorized. A disabled flag is reported as the exact
pilot setup requirement, not enabled by the action.

The required artifact contract is stdout, stderr, exit status, image identity,
pinned checkout identity, bounded endpoint response where applicable, and
cleanup outcome. An unavailable capability, denied image, missing credential,
or missing pilot authorization remains evidence of an incomplete prerequisite;
it is not a successful validation or a reason to retry unchanged work.

## Decisions & Alternatives

| Decision | Chosen | Alternative | Rationale |
| --- | --- | --- | --- |
| Execution entry point | Existing report-only AgentRun | Control-plane shell command | AgentRun retains isolation, budgeting, provenance, cancellation, and cleanup. |
| Capability source | Runner/backend interface | Local Docker socket probe | Backend capabilities describe the selected execution environment; the control plane does not. |
| Tool authorization | Existing attachment, allowlist, and rollout flag | Enable a tool flag from Inbox | Inbox has no rollout authority and must surface the approval needed. |

## References

- [High-level design](../../high-level-design.md)
- [Operator Inbox design](../operator-inbox/operator-inbox-design.md)
- [Marketplace tool-sidecars design](../marketplace-tool-sidecars/marketplace-tool-sidecars-design.md)
- [Partial-closeout recovery design](../partial-closeout-recovery/partial-closeout-recovery-design.md)
