# RDR-060: External Execution Resource Ledger

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-18
- **Status**: Partially Implemented
- **Type**: Architecture + Reliability
- **Priority**: P1
- **Related RDRs**:
  - [RDR-004](RDR-004-container-isolation.md) (Container Isolation)
  - [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution)
  - [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support)
  - [RDR-057](RDR-057-remote-execution-data-contract.md) (Remote Execution Data Contract)
  - [RDR-058](RDR-058-execution-authority-network-and-isolation.md) (Execution Authority, Network Policy, and Isolation)
- **Related Issues**: [#3420](https://github.com/viamin/paid/issues/3420) (closeout), [#3409](https://github.com/viamin/paid/issues/3409), [#3410](https://github.com/viamin/paid/issues/3410), [#3411](https://github.com/viamin/paid/issues/3411), [#3352](https://github.com/viamin/paid/issues/3352), [#3344](https://github.com/viamin/paid/issues/3344), [#3346](https://github.com/viamin/paid/issues/3346), [#3358](https://github.com/viamin/paid/issues/3358)
- **Related Tests**: `spec/jobs/agent_run_resource_janitor_job_spec.rb`, `spec/services/execution_runners_spec.rb`, `spec/services/execution_runners/`, `spec/models/worktree_spec.rb`, `spec/services/containers/pool_manager_spec.rb`

## Implementation Status

**Partially Implemented** as of 2026-08-18. The foundational infrastructure for
tracking and cleaning up execution resources exists across multiple subsystems,
but a unified resource ledger table, provisioning intents, provider ownership
tags, and reconciliation against provider state are not yet implemented.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Externally provisioned execution resources representable in ledger | **Partial** | `ExecutionResourceLedgerEntry` (#3409) now provides a unified `execution_resource_ledger_entries` table covering every resource kind in scope (`primary_environment`, `service`, `sidecar`, `workspace`, `network`, `preview_tunnel`, `temporary_storage`) with lifecycle states, tenant scoping, and secret-free tags — but no provisioning/cleanup code path writes to it yet. Resources are still tracked ad hoc across `agent_runs` (container_id, container_host, runner_handle), `container_pool_entries`, `worktrees`, `docker_hosts`, MCP sidecar containers (`app/services/containers/mcp_provisioner.rb`), and shared service containers (`app/services/containers/service_provisioner.rb`) until Phase 2 (#3410) wires runner provisioning into the ledger |
| Provider resources carry stable Paid ownership tags | **Partial** | Docker containers and volumes are labeled during provisioning (`app/services/containers/provision.rb`) with `paid.managed`, `paid.resource`, `paid.project_id`, and `paid.agent_run_id`/`paid.container_pool_entry_id`, plus deterministic `paid-workspace-{id}` volume naming — but `paid.account_id`, `paid.created_at`, and `paid.resource_kind` are not yet applied. MCP sidecar containers (`McpProvisioner#create_sidecar_container`) and service containers (`ServiceProvisioner#create_docker_container`) fall further short: they only apply a narrow, provisioner-specific label pair (`paid.mcp_sidecar`/`paid.agent_run_id`, and `paid.service_container`/`paid.service_container_id` respectively) with no `paid.managed`, `paid.project_id`, `paid.account_id`, `paid.created_at`, or `paid.resource_kind` |
| Crash-window provisioning intents before provider create calls | **Gap** | `runner_handle` persisted post-provision (#3346); no pre-provision intent record |
| Reconciliation detects ledger/provider drift and retries cleanup | **Gap** | Janitor job retries failed cleanup; no active drift detection against provider state |
| Providers without tag/list support degrade explicitly and safely | **Gap** | No explicit degradation model for providers lacking tag/list APIs |
| Existing Docker janitors work during migration | **Implemented** | `AgentRunResourceJanitorJob`, `CleanupContainerActivity`, `CleanupWorktreeActivity`, `EnqueueJanitorActivity` |

### 2026-08-18 Closeout

Audit recorded against umbrella issue
[#3420](https://github.com/viamin/paid/issues/3420). See
[`audit-report-2026-08-18-rdr-060.md`](audit-report-2026-08-18-rdr-060.md) for
full criterion-by-criterion evidence and gap analysis.

The closeout is **partial**. The shipped implementation provides robust
container and volume lifecycle management through the existing janitor
infrastructure, persisted runner handles for crash recovery, and multi-host
Docker backend tracking. However, the core ledger concept — a unified table
recording every externally provisioned resource with pre-provision intents,
provider ownership tags, and active reconciliation — is not yet built.

Five of seven implementation dependencies remain open:
[#3409](https://github.com/viamin/paid/issues/3409) (ledger data model),
[#3410](https://github.com/viamin/paid/issues/3410) (runner/ledger integration),
[#3411](https://github.com/viamin/paid/issues/3411) (reconciliation),
[#3352](https://github.com/viamin/paid/issues/3352) (idempotent lifecycle),
[#3358](https://github.com/viamin/paid/issues/3358) (runner conformance suite).

## Problem Statement

Paid provisions execution resources on external infrastructure providers —
Docker containers, workspace volumes, network interfaces, and (in future) cloud
VMs and managed-service instances. These resources cost money when running and
leak when orphaned. The current system tracks resources implicitly across
multiple tables (`agent_runs.container_id`, `container_pool_entries`,
`worktrees`) but has no single source of truth for "what did we ask the provider
to create, and is it still there?"

This creates several failure modes:

1. **Crash-window orphans**: If the process crashes between calling the provider
   create API and persisting the identifier, the resource leaks with no record.
2. **Drift**: Provider-side resources can exist without a ledger record (manual
   creation, partial cleanup) or vice versa (stale record after external
   deletion).
3. **No ownership proof**: Without stable tags on provider resources, a
   reconciler cannot distinguish Paid-managed resources from unrelated ones on
   the same provider account.
4. **Provider heterogeneity**: Docker supports labels and container listing;
   future cloud providers may not support tagging or may have different listing
   APIs. The system needs explicit degradation, not silent omission.

## Context

### Existing Resource Tracking

The current codebase tracks execution resources across several subsystems:

- **`agent_runs`**: `container_id`, `container_host`, `runner_handle` (jsonb),
  `worktree_path`, `external_metadata` (carries `planned_container_host`)
- **`container_pool_entries`**: Warm-pool containers with lifecycle states
  (warming, warm, claimed, error)
- **`worktrees`**: Git worktree lifecycle (active, cleaned, cleanup_failed)
- **`docker_hosts`**: Multi-backend host registry with readiness states

### Existing Cleanup Infrastructure

- **`AgentRunResourceJanitorJob`**: Removes containers and volumes for finished
  runs. Retries on Docker errors with polynomial backoff. Resolves cleanup host
  from `runner_handle`, `container_host`, or `external_metadata`.
- **`CleanupContainerActivity`** (Temporal): Calls `agent_run.cleanup_container`
  as a workflow activity with phase tracking.
- **`CleanupWorktreeActivity`** (Temporal): Transitions worktree status from
  active to cleaned.
- **`EnqueueJanitorActivity`** (Temporal): Second-chance cleanup by enqueuing
  the janitor job outside the workflow lifecycle.

### Runner Handle Recovery (#3346 — Closed)

`ExecutionRunners::RunnerHandle` is a Data value object persisted as jsonb on
`agent_runs.runner_handle`. It carries `runner_type`, `identifier` (container
ID), `host`, `workspace_ref` (volume name), and `metadata`. This enables
recovery after worker crash/failover — the handle is deserialized and used to
resume or clean up the execution resource.

### Runner Abstraction (#3344 — Closed)

Logging, status, cancellation, and cleanup are abstracted behind the
`ExecutionRunners::Base` interface. Concrete runners (`LocalDockerRunner`,
future cloud runners) implement `provision`, `start`, `running?`, `cancel`,
and `cleanup`. This is the integration point for ledger operations.

## Decision

### Unified Resource Ledger

Introduce an `execution_resource_ledger_entries` table as the single source of
truth for every externally provisioned resource. Each entry tracks:

- **Resource identity**: provider type, provider resource ID, resource kind
  (container, volume, network, VM)
- **Ownership**: account, project, agent run (optional for pool resources)
- **Lifecycle state**: `intent_created` -> `provisioning` -> `provisioned` ->
  `cleanup_requested` -> `cleaned` -> `verified_gone` (terminal); also
  `orphaned` and `leak_suspected` for reconciliation findings
- **Provider tags**: The ownership tags applied (or attempted) on the provider
  resource
- **Timestamps**: intent created, provisioned, cleanup requested, cleaned,
  last verified

### Provisioning Intents

Before calling a provider create API, write an `intent_created` ledger entry
with enough information to identify or clean up the resource if the create call
succeeds but the process crashes before recording the result. The intent carries:

- The intended provider and resource kind
- The ownership tags that will be applied
- The agent run or pool entry the resource is for

After a successful create, update the entry to `provisioned` with the provider
resource ID.

### Provider Ownership Tags

Apply stable, machine-readable tags/labels to every provider resource where the
backend supports tagging:

- `paid.managed = true`
- `paid.account_id = <account_id>`
- `paid.agent_run_id = <agent_run_id>` (when applicable)
- `paid.resource_kind = container|volume|network`
- `paid.created_at = <ISO 8601>`

For Docker, these map to container labels and volume labels. For cloud
providers, they map to resource tags.

### Reconciliation

A periodic reconciliation job:

1. Lists all provider resources with `paid.managed = true` tags
2. Compares against `provisioned` and `cleanup_requested` ledger entries
3. For provider resources with no ledger entry: marks as `orphaned`, attempts
   cleanup
4. For ledger entries with no provider resource: marks as `verified_gone`
5. For stale `intent_created` entries (older than threshold): marks as
   `leak_suspected`, attempts cleanup using the intended resource identity

### Explicit Degradation

Providers that do not support tagging or listing must declare this in their
runner capability model. When a runner lacks tag support:

- Provisioning intents are still recorded in the ledger
- Cleanup relies solely on the stored provider resource ID
- Reconciliation for that provider is disabled with a logged warning
- No silent omission — the capability gap is visible in operational dashboards

## Acceptance Criteria

1. Every externally provisioned execution resource (containers, volumes,
   worktrees, pool entries) can be represented in the ledger.
2. Provider resources carry stable Paid ownership tags where the backend
   supports tags.
3. Crash-window provisioning intents exist before provider create calls where
   feasible.
4. Reconciliation can detect ledger/provider drift and retry cleanup.
5. Providers without tag/list support degrade explicitly and safely.
6. Existing Docker janitors continue to function during and after migration to
   the ledger.

## Implementation Plan

### Phase 1: Ledger Data Model (#3409) — Implemented

- [x] Create `execution_resource_ledger_entries` table with lifecycle states
- [x] Add model with state machine transitions and validation
- [x] Add association from `agent_runs` (`ContainerPoolEntry` has no ledger
      FK yet; it is not part of this phase's field list and remains future
      work for Phase 2 runner integration)

See `docs/intent/execution-resource-ledger/` for the LLD and EARS specs
(`RESOURCE-LEDGER-001` through `RESOURCE-LEDGER-004`).

### Phase 2: Runner Integration (#3410)

- Integrate ledger intent creation into `ExecutionRunners::Base#provision`
- Apply ownership tags via runner-specific implementations
- Update ledger state on provision success/failure

### Phase 3: Reconciliation (#3411)

- Build reconciliation service that compares ledger vs provider state
- Schedule periodic reconciliation jobs
- Handle orphan detection and cleanup

### Phase 4: Idempotent Lifecycle (#3352)

- Make provision/cleanup operations idempotent using ledger state
- Handle crash recovery using intent records

### Phase 5: Conformance (#3358)

- Runner conformance suite validates ledger integration
- Provider comparison benchmarks include tag/list capability testing

## Alternatives Considered

### Continue with distributed tracking

Keep resource tracking spread across `agent_runs`, `container_pool_entries`,
and `worktrees` without a unified ledger.

**Rejected**: This approach cannot detect crash-window orphans, has no
reconciliation capability, and becomes increasingly fragile as new provider
types are added.

### Event-sourced ledger

Use an append-only event log instead of a mutable state machine.

**Rejected**: Event sourcing adds complexity without proportional benefit for
this use case. The resource lifecycle is linear (create -> use -> cleanup) and
the current state is what matters for reconciliation, not the full event
history.

## Trade-offs

**Positive**:

- Single source of truth for all externally provisioned resources
- Crash-window protection prevents silent resource leaks
- Reconciliation catches drift before it becomes costly
- Explicit degradation prevents silent capability gaps

**Negative**:

- Additional write on every provision/cleanup (mitigated: one row per resource)
- Migration period where both old and new tracking coexist
- Reconciliation job adds provider API load (mitigated: configurable interval)

## Validation

- Unit tests for ledger model state transitions
- Integration tests for provision -> ledger -> cleanup flow
- Reconciliation tests with simulated drift scenarios
- Existing janitor job specs continue to pass unchanged
