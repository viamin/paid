# RDR-057: Remote Execution Data Contract

Date: 2026-08-17
Status: Accepted

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
