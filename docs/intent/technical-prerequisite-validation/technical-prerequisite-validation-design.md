---
parent: partial-closeout-recovery
prefix: TECHNICAL-PREREQUISITE
---

# LLD: Technical Prerequisite Validation

## Design

Prerequisite validation reuses an already-provisioned `AgentRun` and its selected
execution backend. `TechnicalPrerequisites::ExecuteValidation` invokes native
analyzers exclusively through `AgentRun#execute_in_execution_environment`; it
does not inspect or expose the control-plane Docker socket. Placement, pinned
checkout, network policy, image allowlists, sidecar provisioning, cancellation,
and cleanup remain owned by the existing runner and provisioner.

The service records a bounded stdout/stderr/exit-status evidence bundle with
the selected analyzer, tool endpoint identity, image identity when available,
and pinned checkout. Unavailable execution, failed execution, and successful
execution remain distinct. A requested sidecar while
`marketplace_tool_sidecars` is disabled produces an explicit scoped-authorization
setup action; it never enables the flag or retries an unchanged environment.

## Decisions & Alternatives

| Decision | Chosen | Alternative | Rationale |
| --- | --- | --- | --- |
| Execution boundary | Existing AgentRun environment | Control-plane host shell/socket | Preserves isolation and runner policy. |
| Sidecar rollout | Surface required authorization | Enable the flag during validation | Rollout authority remains explicit and scoped. |
