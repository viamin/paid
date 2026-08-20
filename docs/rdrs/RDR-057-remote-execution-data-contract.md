# RDR-057: Remote Execution Data Contract

## Metadata

- **Date**: 2026-08-17
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: #3417 (closeout audit), #3399, #3400, #3401, #3336, #3342, #3350, #3358
- **Related RDRs**:
  - [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution)
  - [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support)

## Implementation Status

Implemented as of 2026-08-17. Paid ships provider-neutral
`ExecutionInputManifest` and `ExecutionOutputManifest` value objects under
`ExecutionRunners`, both using schema version `remote_execution.v1`, with
coverage in the container-runtime LLD/specs and execution-runner test suite.
The shipped contract:

- carries explicit Git, control-plane API, object-storage, and credential lane
  references;
- keeps normal execution workspace description declarative and host-path-free;
- represents durable binary artifacts as object-storage manifest entries; and
- remains compatible with local Docker development through
  `ExecutionRunners::LocalDockerRunner`.

See [audit-report-2026-08-17-rdr-057.md](audit-report-2026-08-17-rdr-057.md).

## 2026-08-17 Closeout

Issue [#3417](https://github.com/viamin/paid/issues/3417) audited the shipped
implementation against this RDR and found no remaining gaps in the accepted
scope. The closeout confirmed:

- `ExecutionInputManifest` carries repository/ref, execution settings,
  prompt/context references, service declarations, and all four transfer lanes.
- `ExecutionOutputManifest` carries result summaries, log references,
  verification payloads, git output identity, and durable binary artifact
  references separated from structured results.
- Secret values and host paths are excluded by construction, while normal
  execution uses a declarative named-volume workspace contract instead of a
  shared host-storage requirement.
- Local Docker remains a supported runner path through
  `ExecutionRunners::LocalDockerRunner`.

No follow-up gap issues were required, so the RDR closes as fully implemented.

## Context

Paid's runner abstraction (`ExecutionRunners`) now separates control-plane
orchestration from the runtime that actually executes agent work. For local
Docker this boundary is still in-process, but a remote runner requires an
explicit, provider-neutral contract for what crosses the boundary in and out of
execution.

That contract must:

- represent the current Docker lifecycle without leaking host paths or Docker
  identifiers into the transport payload,
- preserve the execution inputs the runner needs (repository/ref, execution
  spec, prompt/context references, service declarations),
- preserve the durable outputs the control plane needs (result summary, git
  output identity, logs, verification results, artifact references), and
- keep secrets out of manifests by construction.

## Decision

Define two provider-neutral value objects under `ExecutionRunners`:

- `ExecutionInputManifest`
- `ExecutionOutputManifest`

Both use schema version `remote_execution.v1` and serialize to JSON-native
hashes.

### Input manifest

The input manifest carries:

- `repository`: provider, repo full name, repository URL, and the git ref
  identity (`branch_name`, `base_commit_sha`, `source_pull_request_number`)
- `execution`: agent-run identity plus declarative execution settings
  (`image`, `command`, `resources`, workspace mode/mount point, networking)
- `prompt_refs`: control-plane references to prompt-version or custom-prompt
  data
- `context_refs`: control-plane references to issue or other run context
- `services`: service declarations with `env_keys` only
- `artifact_refs`: reserved for future input artifacts
- `lanes`: explicit refs grouped by the four transport lanes:
  - `git`
  - `control_plane_api`
  - `object_storage`
  - `credentials`

### Output manifest

The output manifest carries:

- `execution`: agent-run identity and terminal metadata
- `result_summary`: success, exit code, OOM status, environment-running flag,
  and output sizes
- `artifacts` separated into:
  - `code_outputs` (git output identity)
  - `binary_artifacts` (durable object-storage references)
  - `structured_results` (verification payloads and future structured outputs)
- `log_refs`: control-plane references to persisted logs
- `verification`: normalized verification result payload
- `git_output`: branch, commit, PR/review identity
- `lanes`: output references grouped by the same four lanes

## Consequences

- Remote runners can receive a single explicit input payload without depending
  on Docker-specific fields or host filesystem paths.
- Durable outputs are typed at the contract boundary instead of inferred from
  runner-specific payloads.
- Secret handling becomes structural: manifests only carry secret identifiers
  (env var names, service names, config keys), never values.
- Future runners can replace local Docker transport details with remote Git,
  API, and object-storage implementations without changing control-plane
  orchestration code.
