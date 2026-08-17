# RDR-057: Remote Execution Data Contract

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-12
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md), [RDR-006](RDR-006-secrets-proxy.md), [RDR-019](RDR-019-remote-container-execution.md), [RDR-020](RDR-020-service-container-architecture.md), [RDR-045](RDR-045-live-web-app-preview-agent-verification.md), [RDR-048](RDR-048-multi-host-docker-backend-support.md), [RDR-058](RDR-058-execution-authority-network-and-isolation.md) (credential lane authority), [RDR-059](RDR-059-immutable-agent-runtime-images.md) (image identity in RunSpec), [RDR-060](RDR-060-external-execution-resource-ledger.md) (external resource ledger), [RDR-061](RDR-061-infrastructure-safety-and-audit.md) (artifact movement audit)
- **Related Issues**: #3336 (runner extraction), #3342 (workspace strategy), #3350 (stateless artifact storage), #3358 (runner conformance)

## Problem Statement

Paid's local Docker execution can still lean on semantics that disappear on cloud runners: Docker named volumes, `docker exec`, local image names, and container-side copies. A remote runner needs a provider-neutral contract for what enters an execution environment and what durable outputs come back.

The decision is not which provider stores bytes. The decision is the transport class for each data type so a run can move through:

```text
Paid control plane -> runner -> isolated execution environment -> durable outputs
```

without shared host storage.

## Context

### Current Implementation

- `AgentExecutionWorkflow` provisions services, MCP servers, browser sidecars, the primary environment, then clones, runs, pushes, screenshots, and cleans up through Temporal activities.
- `ExecutionRunners::RunSpec` and `WorkspaceStrategy` already isolate workspace shape from Docker volumes in `app/services/execution_runners.rb`.
- `Containers::Provision` still resolves `paid-agent:latest`, creates Docker volumes, injects env, labels Docker resources, and applies firewall rules.
- Git clone and push happen inside the environment through `Containers::GitOperations`; GitHub credentials are served through Paid proxy endpoints.
- Durable binary artifacts use `ArtifactStorage` and `Screenshots::Storage`; the inventory is in `docs/ARTIFACT_STORAGE.md`.
- `AgentRunLog`, `TokenUsage`, run state, PR URLs, result commits, and trace metadata live in PostgreSQL.

### Forces and Constraints

- Preserve local Docker as a runner.
- Do not require a shared filesystem between Rails/Temporal workers and the execution environment.
- Treat Git as the source of truth for code changes, not as a blob store for traces or generated binaries.
- Keep durable user-visible binaries off the Rails host filesystem.
- Do not force all providers to expose `exec`, bind mounts, or Docker volume primitives.
- The contract must be narrow enough for a first remote runner to implement.

## Research Findings

- The current runner extraction already separates workspace shape from higher-level orchestration, which means the missing decision is the transport contract, not a new workflow model.
- Existing product behavior already uses different durable stores for different artifact classes: Git for code, PostgreSQL for structured state, and object storage for screenshots and traces.
- The main cloud-readiness gap is that local Docker conveniences still leak into the mental model even where the implementation has begun to abstract them away.
- A provider-neutral contract is more valuable than a provider-specific optimization because the immediate goal is cloud execution portability.

## Proposed Solution

Paid will define a runner data contract with four lanes:

1. **Git lane**: repository input and code output.
2. **Control-plane API lane**: structured execution spec, run status, logs/events, result summaries, and small manifests.
3. **Object-storage lane**: durable binary/user-visible artifacts.
4. **Credential lane**: scoped runtime authority brokered by Paid, never staged as general artifacts.

The runner interface should pass a `RunSpec` that includes repository identity/ref, command/goal, prompt/context references or inline small payloads, workspace strategy, services, network policy, resources, and credential classes required. It should return an `ExecutionResult` plus an output manifest that references durable artifacts by URL/key and code changes by commit/branch/PR identity.

### Contract Details

### Inputs

| Input | Transport | Notes |
|---|---|---|
| Repository + ref/commit | Git | Runner clones/fetches in its workspace using Paid-brokered Git credentials. |
| Execution spec | Runner API / `RunSpec` | Immutable per attempt; includes goal, command, resources, network policy, services, image identity. |
| Prompt/context | Inline when small; object storage or Paid API when large | Knowledge snapshots and prompt assembly should be referenced by ID or artifact key when they exceed normal payload size. |
| Configuration | `RunSpec` env + Paid API | Non-secret config can be env or structured spec. |
| Scoped credentials | Credential lane | See RDR-058; no bulk object staging of secrets. |
| Knowledge/context artifacts | Paid API or object storage | Use object storage for large binary/opaque context, DB/API for structured records. |
| Service requirements | `ServiceDeclaration` | Runner translates to sidecars, managed services, or rejection by capability. |
| Optional existing artifacts | Object storage keys | Runner receives references, not host paths. |

### Outputs

| Output | Transport | Notes |
|---|---|---|
| Code changes | Git | Branch/commit/PR is the authoritative output. |
| Structured execution result | Runner API -> PostgreSQL | Exit code, status, OOM/timeout, summary, timings. |
| stdout/stderr/logs | Streaming API/events -> PostgreSQL | Keep `AgentRunLog` as durable queryable record; large raw logs may later use object storage with DB index. |
| Screenshots, traces, videos, generated binaries | Object storage via `ArtifactStorage` | The manifest stores keys, URLs, content type, size, checksum when available. |
| Verification results | PostgreSQL + optional artifact links | Store pass/fail and trace links, not only free text. |
| Generated files not committed to git | Object storage | Only for user-visible artifacts; implementation files should be committed. |

## Alternatives Considered

### Shared filesystem

Keep using mounted workspaces and shared directories.

- **Pros**: Smallest change for local Docker.
- **Cons**: Not portable to Cloud Run Jobs, Fargate tasks, Fly Machines, or other isolated environments; couples worker hosts to runner storage.
- **Decision**: Keep only as a local Docker compatibility strategy.

### Control-plane HTTP upload/download only

Have runners fetch every input and post every output through Paid APIs.

- **Pros**: Simple authority model; control plane sees all transfers.
- **Cons**: Turns Rails into a bulk data plane; inefficient for large traces, videos, and generated artifacts.
- **Decision**: Use for small structured inputs/results and credential brokering, not large binaries.

### Object storage for all inputs and outputs

Stage everything in S3-compatible storage.

- **Pros**: Portable and durable.
- **Cons**: Git already solves repository transport and merge semantics; secrets should not be staged as objects.
- **Decision**: Use for durable binary artifacts and optional large input artifacts, not code changes or secrets.

### Git for code changes, object storage for binaries, APIs for structured state

Use the smallest durable transport for each artifact class.

- **Pros**: Matches current implementation and cloud constraints.
- **Cons**: Requires a documented manifest so outputs are not scattered.
- **Decision**: Adopt.

## Security Implications

- Secrets are excluded from artifact lanes.
- Artifact keys and manifests must carry account/project/run context and be authorized through Paid before display.
- Object storage credentials should be control-plane held where possible; if a runner needs direct upload credentials, they must be per-run, prefix-scoped, and short-lived.

## Operational Implications

- Rails and Temporal workers can be stateless with respect to execution bytes.
- Provider experiments can compare artifact upload and clone latency without changing orchestration semantics.
- Missing object storage remains acceptable for local development, but production readiness should treat durable artifact storage as required for screenshot/trace features.

## Migration and Compatibility

- Local Docker keeps named-volume workspace execution under `WorkspaceStrategy`.
- Existing screenshot/trace storage remains the object-storage implementation.
- Git branch fallback for screenshots can remain a compatibility path, but not the preferred production artifact lane.
- Runner conformance should verify clone, log streaming, artifact upload, result manifest, and cleanup without shared host paths.

## Trade-offs and Consequences

- The manifest adds one explicit artifact index, but avoids inventing a generic filesystem abstraction.
- Git remains required for code outputs; providers that cannot perform Git operations inside the workload are not suitable for normal create-PR runs.
- Large generated artifacts become durable only when explicitly uploaded and referenced.

## Implementation Plan

1. Extend `ExecutionRunners::RunSpec` and runner result types so each artifact lane is explicit at the contract boundary.
2. Define a durable output manifest shape that references Git outputs, structured results, and uploaded artifacts without host-path assumptions.
3. Keep local Docker compatibility inside `WorkspaceStrategy` while rejecting new shared-filesystem assumptions in remote runner work.
4. Add runner conformance coverage for clone, log streaming, artifact upload, result manifests, and cleanup behavior.
5. Gate production cloud readiness on durable artifact storage for screenshots, traces, and other user-visible binaries.

## Validation

- Verify a local Docker runner still passes the contract with named-volume workspaces and no shared host-path requirement at the orchestration boundary.
- Verify a remote-capable runner can clone from Git, stream logs, upload durable artifacts, and return a manifest without `docker exec` or bind mounts.
- Verify secrets never appear in artifact manifests, durable object keys, or structured result payloads.
- Verify screenshot, trace, and generated-binary retrieval works entirely through Paid-authorized artifact references.

## Open Questions

- Should large raw stdout/stderr streams eventually move from PostgreSQL rows to object storage with indexed summaries?
- Should object-storage direct upload use pre-signed PUT URLs or runner-specific temporary cloud credentials first?
- What maximum inline prompt/context size should trigger object-storage staging?

## Relationship to Existing Work

This RDR does not replace the runner extraction effort (#3336) or workspace isolation (#3342). It fills the data-plane contract those runner APIs must carry so a second runner does not inherit Docker host-storage assumptions.
