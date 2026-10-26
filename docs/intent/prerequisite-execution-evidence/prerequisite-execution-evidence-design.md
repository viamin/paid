---
parent: PAID
prefix: PREREQUISITE-EVIDENCE
---

# Low-Level Design: Prerequisite Execution Evidence

## Purpose

An Inbox prerequisite that needs runtime evidence must be actionable without
confusing the control-plane host with Paid's execution backends. The operator
can prepare or resume a bounded validation on a fresh, pinned `AgentRun`.
The validation invokes a selected native analyzer and, when authorized, a
selected marketplace tool sidecar from the isolated run environment.

## Execution contract

`PrerequisiteExecutionEvidence::Validate` is the capability boundary. Before
provisioning it queries the selected runner/backend capability contract and
the existing host-readiness probe. A missing Docker socket in the process that
opened the Inbox is therefore only local diagnostic information; it is not a
negative placement decision. No compatible backend produces durable
`unavailable` evidence and the exact remediation supplied by the runner or
host probe.

The operation only accepts a persisted AgentRun and commands selected by Paid
configuration. It provisions through `AgentRun#provision_execution_environment`,
executes through `#execute_in_execution_environment`, and always invokes the
normal sidecar and execution-environment cleanup paths. It never runs a
command on the control plane, exposes a host shell, or mounts the Docker
socket. Native analyzer output and bounded sidecar responses are durable run
logs; identity, status, endpoint metadata, and cleanup result are retained in
`verification_result`.

The marketplace sidecar remains independently rollout-authorized. If
`marketplace_tool_sidecars` is off, the result is `unavailable` and identifies
the scoped pilot enablement action. Validation never changes a feature flag,
credential, image allowlist, or authorization. Image-denial and provisioning
errors are similarly recorded as evidence rather than retried against an
unchanged backend.

## Lifecycle and reconciliation

Every request re-evaluates current host capability, flag state, image policy,
and the run's pinned identity before starting. A cancellation is terminal for
that attempt and preserves evidence collected before cleanup. Retry is
idempotent at the persisted run boundary: a completed successful validation is
returned without re-execution; unavailable, failed, partial, and cancelled
attempts can be deliberately re-run after the current conditions are checked.
The durable receipt is linked to the originating run, allowing the existing
partial-closeout assessment and prerequisite owner to assess it without
claiming source completion.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Runtime selection | Existing runner capability and host-readiness interfaces | Probe the Inbox/control-plane Docker socket | Placement belongs to execution infrastructure; a local socket is neither necessary nor sufficient. |
| Evidence storage | Existing AgentRun result and logs | A parallel evidence workflow/model | The run already owns pinned checkout identity, output retention, and cleanup lifecycle. |
| Tool authorization | Fail closed with an explicit pilot action | Enabling the rollout flag from validation | A validation action cannot grant rollout authority. |

## References

- [Container runtime LLD](../container-runtime/container-runtime-design.md)
- [Marketplace tool sidecars LLD](../marketplace-tool-sidecars/marketplace-tool-sidecars-design.md)
- [Partial-closeout recovery LLD](../partial-closeout-recovery/partial-closeout-recovery-design.md)
