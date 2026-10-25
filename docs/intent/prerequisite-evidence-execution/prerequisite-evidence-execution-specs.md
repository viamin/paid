# EARS Specs: Prerequisite Evidence Execution

> Segment: prerequisite-evidence-execution · LLD:
> [prerequisite-evidence-execution-design.md](prerequisite-evidence-execution-design.md)

## Capability inspection

- [x] **PREREQ-EXEC-001** When an operator inspects execution capabilities for a project, the system shall derive execution-host capability from the configured Docker hosts' placement readiness through the provisioner's placement scopes, without probing the control plane's local Docker socket.
- [x] **PREREQ-EXEC-002** When no configured Docker host is placement-ready for agent runs, the system shall report the environment unavailable and list, per non-ready host, the failing readiness signal and the exact operator setup action.
- [x] **PREREQ-EXEC-003** When the `marketplace_tool_sidecars` flag is off for the project's tenant and a tool is selected, the system shall report the flag as a missing authorization carrying the exact admin enable action, and shall not enable the flag.
- [x] **PREREQ-EXEC-004** When the selected tool's image is not in the account's operator allowlist, the system shall report the exact allowlist action for that image as a missing authorization.
- [x] **PREREQ-EXEC-005** When the environment is available but a required authorization is missing, the system shall report the validation startable only after the named authorized action, without provisioning a partial attempt.

## Bounded validation lifecycle

- [x] **PREREQ-EXEC-006** When an authorized operator starts a validation for an open prerequisite issue of the project, the system shall create one bounded validation pinned to the requested branch with an explicit contract (native analyzer command plus optional selected tool), idempotent while an attempt is active.
- [x] **PREREQ-EXEC-007** The validation shall provision and execute exclusively through the AgentRun provision/execute/cleanup contract on an isolated run container, and shall neither mount the Docker socket nor expose host shell access to make validation work.
- [x] **PREREQ-EXEC-008** The validation shall materialize the pinned checkout through the container git-operations path and record the resolved commit SHA, the run container identity, and the container host as checkout/run identity evidence.
- [x] **PREREQ-EXEC-009** The validation shall run the native analyzer command inside the run container through `execute_in_execution_environment` and durably record its exit status and bounded stdout/stderr.
- [x] **PREREQ-EXEC-010** When the contract includes a tool, the validation shall attach it through the marketplace attachment path, provision it through the flag- and allowlist-gated tool-sidecar provisioner, and call the provisioned endpoint from inside the run container, recording endpoint and response evidence.
- [x] **PREREQ-EXEC-011** The validation shall distinguish `unavailable`, `failed`, `partial`, `cancelled`, and `succeeded` terminal outcomes, and shall mark the paired AgentRun with the matching terminal status.
- [x] **PREREQ-EXEC-012** The validation shall always attempt cleanup of provisioned sidecars, the run container, and the temporary workspace, and shall record the cleanup disposition as evidence whether the steps succeeded or not.
- [x] **PREREQ-EXEC-013** When an operator cancels an active validation, the system shall preserve collected steps, run cleanup, and mark both the validation and its paired run cancelled.
- [x] **PREREQ-EXEC-014** When an operator retries a validation, the system shall return the existing evidence for a succeeded attempt of the same scope, shall refresh an unchanged unavailable attempt in place without provisioning, and shall start a fresh attempt — marking prior evidence stale — when the scope (branch, command, tool, or tool-flag state) changed.

## Inbox, API, and evidence linkage

- [x] **PREREQ-EXEC-015** The prerequisite Inbox surface shall render the capability report, the exact authorized setup/approval action for every missing requirement, and the bounded validation action for each linked open prerequisite issue.
- [x] **PREREQ-EXEC-016** Validation status, steps, and evidence shall be readable by an authorized operator through the project UI and the JSON API surface.
- [x] **PREREQ-EXEC-017** A completed validation shall record its evidence against the prerequisite issue without closing, commenting on, or re-labeling the GitHub issue, so missing execution evidence keeps the owner open.
