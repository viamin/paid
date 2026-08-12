# RDR-058: External Execution Resource Ledger

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-12
- **Status**: Draft
- **Type**: Architecture + Operations
- **Priority**: P1
- **Related RDRs**: [RDR-019](RDR-019-remote-container-execution.md), [RDR-020](RDR-020-service-container-architecture.md), [RDR-045](RDR-045-live-web-app-preview-agent-verification.md), [RDR-048](RDR-048-multi-host-docker-backend-support.md)
- **Related Issues**: #3336, #3344, #3346, #3352

## Problem Statement

Paid already has idempotent Docker provisioning, runner handles, stale-run cleanup, and Docker orphan janitors. Cloud execution adds a harder failure window: a provider may create a billable resource, then the worker process may crash before `AgentRun#runner_handle` is persisted. A retry cannot clean up what Paid never recorded unless the resource is discoverable by stable Paid identifiers.

The question is whether Paid needs a distinct resource registry. The answer is yes, but it should be a narrow execution resource ledger, not a generic infrastructure CMDB.

## Current Implementation

- `AgentRun` stores `container_id`, `container_host`, and `runner_handle`.
- `Containers::Provision` labels Docker containers and workspace volumes with project/run/pool identifiers.
- `ServiceContainer` stores Docker container IDs and has `runner_handle` for the runner-extraction migration.
- `PreviewSession` and preview tunnel labels carry preview-specific identifiers.
- `AgentRuns::CleanupStale`, `DockerOrphanCleanupJob`, service cleanup, MCP cleanup, and workspace cleanup reconcile known Docker resources.
- Issue #3352 already proposes stable tags, pre-provision intent, orphan reconciliation, cleanup retry, and a failure-window matrix.

## Forces and Constraints

- Do not duplicate the runner handle; the ledger complements it.
- Support resources that are not Docker containers: jobs, machines, tasks, disks, networks, tunnels, temporary storage.
- Temporal retries and worker restarts must not create duplicate billable resources without a cleanup path.
- Providers differ in tag support and list APIs.
- Keep the first version small.

## Options Considered

### Only persist `RunnerHandle`

- **Pros**: Already exists; simple.
- **Cons**: Does not cover crash-before-handle-persisted resources.
- **Decision**: Insufficient.

### Provider-native tags only

- **Pros**: No new table; resources discoverable externally.
- **Cons**: Paid cannot track cleanup attempts, failures, or providers without good tag listing.
- **Decision**: Necessary but not sufficient.

### Generic infrastructure inventory

- **Pros**: Could model every cloud resource.
- **Cons**: Overbuilt; Paid only needs execution lifecycle ownership.
- **Decision**: Reject.

### Narrow execution resource ledger

- **Pros**: Captures ownership, lifecycle, and reconciliation without cloud taxonomy sprawl.
- **Cons**: Adds one durable model and runner contract requirements.
- **Decision**: Adopt.

## Decision

Paid should record every externally provisioned execution resource in an execution resource ledger. The ledger records ownership and lifecycle, while `RunnerHandle` remains the opaque handle used for active runner operations.

Minimum fields:

- account_id, project_id, agent_run_id;
- execution attempt identifier;
- runner/backend key;
- resource kind (`primary_environment`, `service`, `browser`, `mcp_sidecar`, `workspace`, `network`, `preview_tunnel`, `temporary_storage`);
- provider resource ID and provider region/location when applicable;
- stable Paid tags applied to the provider resource;
- status (`provisioning`, `active`, `cleanup_pending`, `deleted`, `orphaned`, `cleanup_failed`);
- created_at, observed_at, deleted_at;
- cleanup error and retry metadata;
- runner handle reference when known.

## Ownership and Lifecycle Semantics

- A provisioning intent row is created before the provider create call when the runner can identify the intended resource kind.
- Provider resources are tagged with stable Paid identifiers: environment, account, project, agent run, attempt, resource kind.
- When provider creation succeeds, the ledger row records provider ID and links to the runner handle.
- Cleanup moves resources through `cleanup_pending` to `deleted`; transient failures remain durable for retry.
- Reconciliation compares ledger rows and provider-listed tagged resources:
  - ledger active + provider missing => mark observed gone, clear active handle if appropriate;
  - provider tagged + no active run/ledger => adopt as orphan and cleanup;
  - ledger cleanup_pending + provider present => retry cleanup;
  - provider cannot list tags => handle-based cleanup only, runner capability reflects the limitation.

## Security Implications

- Tags must not contain secret values.
- Resource ownership tags support security audit and emergency cleanup.
- Cross-account deletion must be guarded by account/project/run ownership checks in Paid, not only provider tags.

## Operational Implications

- Operators get a single place to answer "what execution resources does Paid believe exist?"
- Reconciliation can be scheduled independently of Temporal activity retries.
- Provider APIs with weak tagging/listing remain usable but lower confidence; they need tighter runtime limits and manual runbooks.

## Migration and Compatibility

- Docker runner can initially populate ledger rows from existing labels and handles while keeping existing janitors.
- Existing `container_id`/`container_host` stay for compatibility until the runner extraction effort removes Docker leakage from higher layers.
- Issue #3352 remains the implementation vehicle for failure windows; this RDR supplies the durable resource concept.

## Consequences and Trade-offs

- A ledger is extra state that can drift, so reconciliation is mandatory.
- It avoids a provider-specific resource table per backend.
- It creates the substrate for infra cost accounting without becoming customer billing.

## Open Questions

- Should execution attempt be a new first-class model or derived from Temporal attempt/run metadata?
- Which resources are worth ledgering for local Docker development versus cloud production?
- What retention period should deleted ledger rows use?

## Relationship to Existing Work

This RDR narrows #3352's resource-tagging and cleanup requirements into a durable data model. It does not replace runner handles or existing Docker janitors.
