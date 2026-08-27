# Execution Runner Authoring Guide

This guide documents the current control-plane-to-runner boundary for the
historical execution-runner workstream tracked by `#3336`–`#3348`. It is the
author-facing companion to
[`container-runtime-design.md`](./container-runtime-design.md) and
[`container-runtime-specs.md`](./container-runtime-specs.md).

The old provisional `RDR-054` label on those issues is historical only. In the
current repository, `docs/rdrs/RDR-054-prompt-assembly-service.md` is Prompt
Assembly Service. Runner-boundary work belongs to the container-runtime segment
and the later execution-runner RDRs (`RDR-057`, `RDR-060`, `RDR-062`), not to
Prompt Assembly Service.

## Boundary Summary

The runner boundary exists so orchestration code asks for an execution
environment in provider-neutral terms and the concrete runner translates that
request into Docker, or a future non-Docker runtime, privately.

Control-plane flow today:

1. `AgentRun` and Temporal activities build a provider-neutral
   `ExecutionRunners::RunSpec`.
2. `ExecutionRunners.resolve_for(agent_run)` selects the concrete runner.
3. The runner provisions the workload environment and returns a persisted
   `ExecutionRunners::RunnerHandle`.
4. Later lifecycle calls (`start`, `running?`, `status`, `cancel`, `cleanup`,
   supporting-service methods) use only the handle plus runner-local arguments.
5. The runner returns provider-neutral `ExecutionResult` and
   `ExecutionStatus` objects back to orchestration code.

The boundary is intentionally shaped around the current shipped Docker behavior,
not a speculative generic platform API.

## Control Plane To Runner Map

The easiest way to reason about a second runner is to keep the ownership split
explicit:

| Concern | Control plane owns | Runner owns |
|---|---|---|
| Run intent | `AgentRun`, Temporal activity inputs, `RunSpec.from_agent_run` | Validating that the spec is supportable on the concrete runtime |
| Runtime selection | `ExecutionRunners.resolve_for(agent_run)` / `resolve(backend:)` | Provider API client selection and translation details |
| Durable identity | Persisting `runner_handle` on `agent_runs` | Returning a `RunnerHandle` rich enough for reconnect/recovery |
| Workload lifecycle | Calling `provision`, `start`, `status`, `cancel`, `cleanup` | Creating, starting, observing, stopping, and deleting runtime resources |
| Supporting topology | Deciding that services/MCP/browser are needed | Provisioning and cleaning those resources through the runner methods |
| Policy intent | Networking/ingress/resource/workspace intent on `RunSpec` | Translating intent into native networks, gateways, filesystems, disks, and quotas |
| Recovery | Loading `RunnerHandle` from the DB and deciding reuse vs reprovision | Reconnecting from the handle alone and answering lifecycle queries |
| Conformance | Shared examples and no-shared-filesystem checks | Passing the shared contract without leaking provider vocabulary |

If a detail belongs in the right column, it should not leak upward into
orchestration code as a Docker- or provider-specific field.

## Shared Contract

Every concrete runner subclasses `ExecutionRunners::Base` and implements the
same lifecycle surface:

- Primary environment: `provision`, `start`, `running?`, `reconnect`, `status`,
  `cancel`, `cleanup`
- Supporting topology: `provision_services`, `cleanup_services`,
  `provision_mcp_servers`, `cleanup_mcp_servers`,
  `provision_browser_container`
- Compatibility and health: `.compatible?`, `.ping`
- Reconciliation and ledger capabilities: `#resource_kind`,
  `#supports_tagging?`, `#supports_listing?`,
  `#supports_tag_reconciliation?`, `#list_resources_by_tags`,
  `#cleanup_resource`

The method names and parameter names are part of the contract. They must stay
free of Docker-specific vocabulary such as `container_id`, `docker exec`,
`bind_mount_path`, or Docker network names.

## Core Domain Objects

These value objects are the runner-facing language a second implementation must
speak:

- `RunSpec`: full execution intent. It carries the `AgentRun`, image, command,
  environment, resources, networking policy, ingress policy, workspace
  strategy, supporting services, and secrets configuration.
- `RunnerHandle`: opaque, JSON-serializable identity for a provisioned
  execution environment. It is the only durable reconnection input for later
  lifecycle calls after worker restart or failover.
- `ExecutionResult`: terminal workload outcome, including stdout/stderr,
  success/failure, exit code, timeout classification, and OOM classification.
- `ExecutionStatus`: point-in-time lifecycle status (`:running`, `:exited`,
  `:oom_killed`, `:not_found`) without exposing provider API payloads.
- `NetworkingPolicy`: provider-neutral egress intent. The runner translates it
  privately into platform-specific networks, gateways, or firewalls.
- `WorkspaceStrategy`: provider-neutral workspace mode (`:named_volume`,
  `:bind_mount`, `:ephemeral`, `:object_storage`) plus declarative writable-dir
  and heartbeat intent.
- `ServiceDeclaration`: provider-neutral description of a supporting service
  container or sidecar dependency.
- `ExecutionResources`: resolved CPU, memory, disk, architecture, and timeout
  tuple the runner must honor or reject explicitly.

The minimum expectations for each object are:

| Object | What a runner may assume | What a runner must not assume |
|---|---|---|
| `RunSpec` | The full point-in-time execution request is present: command, env, image, services, networking, ingress, workspace, resources, secrets lanes, and the backing `AgentRun` | That orchestration will later pass the original spec back into `status`, `cancel`, or `cleanup` |
| `RunnerHandle` | It is the durable recovery token. `runner_type`, `identifier`, `host`, `workspace_ref`, and `metadata` are for the runner's private reconnect logic | That `container_id`/`container_host` columns are the real contract |
| `ExecutionResult` | It is the terminal outcome returned to orchestration and manifests. Classify success, exit code, timeout, OOM, and captured output here | That callers will inspect provider-native response payloads |
| `ExecutionStatus` | It is the lifecycle snapshot for retries/recovery (`:running`, `:exited`, `:oom_killed`, `:not_found`) | That callers will ask the provider directly whether a workload still exists |
| `NetworkingPolicy` | It carries intent (`mode`, `allow_destinations`, `egress_profile`, predicates) | That Docker bridge names or firewall syntax may appear on the contract |
| `WorkspaceStrategy` | It carries storage intent (`mode`, `mount_point`, `reference`, `writable_dirs`, `heartbeat`) | That host paths or Docker volume names are available unless the strategy itself declares them |
| `ServiceDeclaration` | It is the provider-neutral service shape (`name`, `image`, `port`, `env`, `type`) for supporting topology | That service startup should be inferred from Docker-specific models |
| `ExecutionResources` | It is the resolved resource tuple, not a preset label | That the runner may silently round or drop unsupported resource requests |

The rule for a second runner is simple: if the value object already names the
intent, extend or reject that object; do not add a parallel provider-specific
parameter path.

## Registration Points For A Second Runner

A new runner implementation is not complete until it is reachable from the same
resolution and recovery paths the Docker runner uses today.

Required registration points:

1. Add the concrete class under `app/services/execution_runners/`.
2. Extend `ExecutionRunners.resolve(backend:)` so backend selection can return
   the new class.
3. Extend `ExecutionRunners.for_type(runner_type)` so persisted
   `RunnerHandle#runner_type` values can be deserialized during cleanup and
   reconciliation.
4. Extend `ExecutionRunners.reconciliation_runners` if the new runner supports
   periodic resource reconciliation.
5. Ensure `.compatible?(spec:, backend:)` rejects unsupported capabilities and
   unsupported networking intent before provisioning side effects.
6. Ensure `#provision` persists a `RunnerHandle` that is sufficient for
   `#reconnect`, `#running?`, `#status`, `#cancel`, and `#cleanup` without the
   original `RunSpec`.

If a runner cannot support a current Paid feature, it should fail closed at the
compatibility boundary rather than silently degrading execution semantics.

In practice, implementation usually proceeds in this order:

1. Start with `.capabilities(backend:)` and `.compatible?(spec:, backend:)` so
   unsupported host paths, service topology, architectures, or egress modes
   fail before side effects.
2. Implement `#provision` and `#cleanup` around a durable `RunnerHandle`.
3. Implement `#start`, `#running?`, `#status`, and `#cancel` strictly from the
   handle path used during retry/recovery.
4. Add supporting-topology methods only for the features the runtime can
   actually honor today.
5. Register the runner only after the shared contract passes, so
   `resolve`/`for_type` never expose a partially conforming implementation.

## Validation And Shared Coverage

A second runner is expected to pass the same shared examples and conformance
checks as `LocalDockerRunner`.

Required shared coverage:

- `spec/support/shared_examples/execution_runner_contract.rb`
  This is the broad lifecycle, timeout, cancellation, cleanup, provisioning
  ledger, and ownership-tag contract.
- `spec/support/shared_examples/no_shared_filesystem_conformance.rb`
  This is the host-path-free create-PR conformance suite from `RDR-057`.
- `spec/support/shared_examples/secure_execution_runner_contract.rb`
  Use this when the runner exposes security-sensitive execution behavior the
  same way the Docker implementation does.

Relevant baseline specs:

- `spec/services/execution_runners/base_spec.rb`
- `spec/services/execution_runners/local_docker_runner_spec.rb`
- `spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb`

What each shared suite proves:

| Coverage | What it checks | Why a second runner should care |
|---|---|---|
| `execution_runner_contract` | lifecycle, handle durability, cleanup, cancellation, ownership tags, provisioning ledger behavior | This is the minimum semantic contract for any real runner |
| `no_shared_filesystem_conformance` | host-path-free create-PR flow, manifest/handle path hygiene, streamed logs, object-storage/control-plane output lanes | This is the main "not accidentally Docker-shaped" gate |
| `secure_execution_runner_contract` | security-sensitive execution and policy behavior for runtimes that expose the same controls | Use this whenever the new runner surfaces the same trust boundary as Docker |

The conformance suite is the closeout check for “not accidentally Docker
shaped.” It proves that:

- the canonical create-PR scenario provisions without a host worktree path,
- logs cross the boundary as streamed stdout/stderr chunks from `#start`,
- handles and manifests do not leak host filesystem paths, and
- the public contract surface does not grow Docker `exec` or bind-mount terms.

## Optional Fake Runner Spike

The repository already includes `ExecutionRunners::ContractRunner`, an in-memory
test double that implements `ExecutionRunners::Base`. Use it when the clearest
way to prove a new idea is to spike the contract before integrating a real
provider SDK.

Good uses for `ContractRunner`:

- narrow supported networking modes with `.supporting(...)`,
- exercise `.compatible?` failure behavior,
- prove shared examples for a new contract shape before wiring a real backend,
- model a future remote runner in design or review discussions without adding a
  production provider implementation.

This serves the “optional fake runner” goal without expanding the shipped
runtime with another provider adapter prematurely.

Minimal spike pattern:

```ruby
runner_class = ExecutionRunners::ContractRunner.supporting(%i[no_outbound proxy_only])
runner = runner_class.new

compatibility = runner_class.compatible?(spec: spec, backend: backend)
handle = runner.provision(spec: spec) if compatibility.compatible?
result = runner.start(handle: handle, command: spec.command)
```

That is enough to prove the authoring path, rejection path, and shared examples
without introducing a premature production runner.

## Migration And Persistence Shape

The durable migration shape is already provider-neutral even though Docker
compatibility columns still exist:

- `agent_runs.runner_handle` stores the serialized `RunnerHandle`
- `container_pool_entries.runner_handle` and `service_containers.runner_handle`
  exist so pool and service-container paths can store the same durable handle
  shape
- older Docker-specific columns such as `container_id`, `container_host`,
  `service_container_ids`, and `docker_container_id` remain in place for
  compatibility and adjacent code paths

A second runner should treat `runner_handle` as the authority for runner-level
recovery. Docker compatibility columns are not the contract to extend.

## Current Docker-Specific Leaks

The boundary is reusable, but it is not perfectly provider-agnostic yet. These
leaks are known and should be called out in design review for any new runner:

- `WorkspaceStrategy#writable_dirs` is provider-neutral intent, but
  `Containers::Provision#host_config` still hardcodes Docker tmpfs mounts.
  This is the deferred work tracked by `CONTAINER-RUNTIME-012`.
- `WorkspaceStrategy#heartbeat` is provider-neutral intent, but callers still
  pass `heartbeat_path:` to `#start` and Docker code still owns heartbeat-dir
  setup/cleanup. This is the deferred work tracked by
  `CONTAINER-RUNTIME-013`.
- `Containers::PoolManager` still constructs Docker named-volume identifiers
  directly for pool workspaces instead of routing that through the runner.
  This is the deferred work tracked by `CONTAINER-RUNTIME-014`.
- Supporting-service, MCP-sidecar, and browser-container lifecycle methods are
  routed through the runner boundary, but the Temporal activities still map
  one-to-one to the existing Docker-centric provisioners and retain their error
  classes in Phase 1.
- Recovery and adjacent operations still carry Docker compatibility fields in
  the database (`container_id`, `container_host`, service-container ids). Those
  fields are legacy/interoperability residue, not the model a new runner should
  copy upward into the contract.
- `ExecutionRunners.resolve`, `for_type`, and `reconciliation_runners`
  currently hardcode the Docker implementation, so adding a new runner still
  requires an explicit registry edit rather than data-driven plugin discovery.

These are acceptable current constraints as long as a second runner rejects
unsupported features explicitly instead of pretending the leaks do not exist.

## Author And Reviewer Workflow

Use this sequence for closeout on a real second-runner change:

1. Confirm the intended backend/runtime maps to the existing contract objects.
   If it needs new intent, update the LLD/EARS first rather than smuggling a
   provider detail into a method signature.
2. Implement the runner behind `ExecutionRunners::Base` and keep all
   provider-specific SDK, API, and naming details inside the concrete class.
3. Register the runner in `resolve`, `for_type`, and reconciliation only where
   its supported feature set makes that valid.
4. Run the shared examples and no-shared-filesystem conformance before trusting
   backend-specific integration tests.
5. Document every unsupported current Paid feature explicitly in the runner's
   compatibility behavior and in the guide/LLD if the limitation is structural.
6. Review the final contract surface for leaked provider vocabulary. If the new
   API name sounds like a provider primitive, it is probably the wrong layer.

## Review Checklist For A New Runner

Use this checklist during implementation review and closeout:

1. The runner is reachable from `resolve`, `for_type`, and any needed
   reconciliation registry.
2. `.compatible?` rejects unsupported capabilities and networking intent before
   side effects.
3. `#provision` returns a durable `RunnerHandle` that later lifecycle calls can
   use without the original `RunSpec`.
4. `#start` yields streamed stdout/stderr chunks and returns an
   `ExecutionResult`.
5. Shared examples and no-shared-filesystem conformance pass for the new class.
6. Any unsupported feature is named explicitly in docs/specs and fails closed.
7. No new public contract term leaks Docker implementation vocabulary.
