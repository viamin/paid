# EARS Specs: Container Runtime

> Testable claims for the shipped container execution, routing, service, and
> capacity model.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **CONTAINER-RUNTIME-001** — When an agent run is provisioned without an
  explicit `worktree_path`, the system SHALL use a per-run Docker named volume
  for `/workspace` so the repository clone happens inside the container. When a
  `worktree_path` is supplied explicitly, the system SHALL treat it as a legacy
  bind-mount compatibility path instead of the normal default.
  *Tests:* `spec/services/containers/provision_spec.rb`,
  `spec/models/agent_run_spec.rb`
  *Code:* `Containers::Provision`, `AgentRun#provision_container`

- [x] **CONTAINER-RUNTIME-002** — When Paid resolves Docker host placement for
  a new run, the system SHALL record explicit or preferred host-selection
  metadata, and capacity-aware preferred placement SHALL leave `container_host`
  blank until queue scheduling selects and provisions a real backend resource.
  *Tests:* `spec/requests/agent_runs_spec.rb`,
  `spec/services/containers/backend_scheduler_spec.rb`
  *Code:* `Containers::ResolveHostForRun`, `Containers::BackendScheduler`

- [x] **CONTAINER-RUNTIME-003** — When a run has been admitted to a host but no
  concrete backend resource has yet recorded `container_host`, the system SHALL
  attribute per-host capacity accounting and workspace-volume cleanup to
  `external_metadata["planned_container_host"]` so multi-host admission and
  cleanup route to the owning backend instead of the local default.
  *Tests:* `spec/services/capacity/run_admission_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/models/agent_run_spec.rb`
  *Code:* `AgentRun.active_count_for_host`, `AgentRun#workspace_volume_host`

- [x] **CONTAINER-RUNTIME-004** — When an agent run needs project service
  containers, the system SHALL record `service_container_ids` before container
  startup, provision or reuse the services on the selected backend/network,
  inject per-service environment variables into the run, and stop services only
  after no in-flight runs still reference them.
  *Tests:* `spec/services/containers/service_provisioner_spec.rb`
  *Code:* `Containers::ServiceProvisioner`

- [x] **CONTAINER-RUNTIME-005** — When Paid collects Docker capacity for a
  backend, the system SHALL classify visible usage into Paid control-plane,
  Paid agent, Paid service-container, and other-Docker buckets, cache the
  snapshot briefly, and degrade conservatively when daemon reads or container
  sampling fail.
  *Tests:* `spec/services/capacity/docker_snapshot_spec.rb`
  *Code:* `Capacity::DockerSnapshot`

- [x] **CONTAINER-RUNTIME-006** — When auto run-concurrency mode is enabled,
  the system SHALL combine the Docker snapshot budget with hard host, user,
  project, and create-PR ceilings; degraded snapshot paths SHALL fall back
  conservatively, and sampling-budget exhaustion SHALL deny that admission
  attempt instead of optimistic overcommit.
  *Tests:* `spec/services/capacity/run_admission_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`
  *Code:* `Capacity::RunAdmission`

- [x] **CONTAINER-RUNTIME-007** — The system SHALL define a provider-neutral
  runner interface (`ExecutionRunners::Base`: `provision`, `start`, `running?`,
  `reconnect`, `status`, `cancel`, `cleanup`, `compatible?`, `ping`) whose method names and
  parameters do not reference Docker concepts (no `container_id`, network name,
  bind mount, or `exec`). A runner owns the complete execution environment and
  the watchdog logic (startup, idle, wall-clock, heartbeat, abort-pattern
  detection).
  *Tests:* `spec/services/execution_runners/base_spec.rb`
  *Code:* `ExecutionRunners::Base`

- [x] **CONTAINER-RUNTIME-008** — `ExecutionRunners::RunnerHandle` SHALL be
  JSON-serializable and round-trip losslessly through `to_json` / `from_json`
  (including the `runner_type` symbol) so it can be persisted in a DB column or
  Temporal activity result for recovery after worker restart or failover. The
  system SHALL persist a `runner_handle` jsonb column on `agent_runs` (alongside,
  not replacing, `container_id`/`container_host`) and SHALL provide
  `RunnerHandle.from_record` / `RunnerHandle#to_storage` for DB round-trip.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::RunnerHandle`

- [x] **CONTAINER-RUNTIME-009** — The system SHALL define immutable value
  objects (`RunSpec`, `RunnerHandle`, `ExecutionResult`, `NetworkingPolicy`,
  `ServiceDeclaration`, `ComputeRequirements`) as `Data.define` structures that
  consolidate the existing `Containers::Provision::Result` patterns and adapt
  `NetworkPolicy::NetworkContract` without Docker-specific identifiers.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners`

- [x] **CONTAINER-RUNTIME-010** — The system SHALL provide a
  `ExecutionRunners::LocalDockerRunner` that implements `ExecutionRunners::Base`
  as a thin adapter over `Containers::Provision`, translating `RunSpec` to
  `Containers::Provision` calls and `Containers::Provision::Result` /
  `Containers::Provision` errors to `ExecutionResult` / `ExecutionRunners`
  errors, without modifying `Containers::Provision` itself.
  `LocalDockerRunner#reconnect(handle:)` SHALL translate the handle identifier
  back to a Docker container ID and delegate to `Containers::Provision.reconnect`.
  `ExecutionRunners.resolve` SHALL return a `LocalDockerRunner` for all current
  (Docker-only) backends.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::LocalDockerRunner`, `ExecutionRunners.resolve`

- [x] **CONTAINER-RUNTIME-011** — The system SHALL express workspace storage as
  a provider-neutral `WorkspaceStrategy` (`mode`, `mount_point`, `reference`,
  `writable_dirs`, `heartbeat`) carried on `RunSpec`, so workspace assumptions
  are isolated from Docker volumes and bind mounts. `LocalDockerRunner` SHALL
  translate the `:named_volume` and `:bind_mount` modes to Docker volume and
  bind-mount operations and SHALL own volume-name construction; no
  orchestration code or domain model SHALL construct Docker volume names.
  `AgentRun#cleanup_orphaned_workspace_volume` SHALL delegate to the runner.
  The `writable_dirs` and `heartbeat` fields on the strategy define the
  provider-neutral shape (declarative data + helper) for the writable
  layout and heartbeat observation but are not yet consumed by the
  Docker executor — see CONTAINER-RUNTIME-012 and CONTAINER-RUNTIME-013.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/models/agent_run_spec.rb`
  *Code:* `ExecutionRunners::WorkspaceStrategy`,
  `ExecutionRunners::LocalDockerRunner`, `AgentRun#cleanup_orphaned_workspace_volume`

- [D] **CONTAINER-RUNTIME-012** — `LocalDockerRunner` SHALL translate
  `WorkspaceStrategy#writable_dirs` into Docker tmpfs mounts so the
  workload's writable layout is declared via the strategy rather than
  hardcoded in `Containers::Provision#host_config`. Today
  `Containers::Provision#host_config` still hardcodes `/tmp` and
  `/home/agent/.cache` tmpfs entries; the `WritableDir#docker_tmpfs_options`
  helper exists to power this translation when it lands. Pool workspace
  reuse through the runner (`paid-pool-workspace-<id>`) is deferred to
  CONTAINER-RUNTIME-014.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/containers/provision_spec.rb`
  *Code:* `ExecutionRunners::LocalDockerRunner#provision`,
  `Containers::Provision#host_config`

- [D] **CONTAINER-RUNTIME-013** — Heartbeat monitoring SHALL be owned by the
  execution runner rather than by callers, so callers never reach into Docker
  host bind mounts or in-container tmpfs mechanics for heartbeat observation.
  Today `WorkspaceStrategy#heartbeat` (`HeartbeatConfig`) is declared on the
  strategy as the provider-neutral shape but is not yet consumed by the
  runner; callers still pass `heartbeat_path:` to `LocalDockerRunner#start`
  and `Containers::Provision#prepare_heartbeat_dir!` / `#cleanup_heartbeat_dir!`
  still own the host temp-dir vs. in-container tmpfs selection.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`
  *Code:* `ExecutionRunners::LocalDockerRunner#start`,
  `Containers::Provision#prepare_heartbeat_dir!`

- [D] **CONTAINER-RUNTIME-014** — Pool workspace management SHALL flow through
  the runner interface so a future remote runner can substitute its native
  storage primitive (object storage, ephemeral disk) for the current Docker
  named-volume pool entry (`paid-pool-workspace-<id>`). Today
  `Containers::PoolManager` still constructs the Docker named-volume name
  directly when claiming a pool entry.
  *Tests:* `spec/services/containers/pool_manager_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`
  *Code:* `ExecutionRunners::LocalDockerRunner`, `Containers::PoolManager`

- [x] **CONTAINER-RUNTIME-015** — The system SHALL define an
  `ExecutionRunners::ExecutionStatus` domain object (`state`, `exit_code`,
  `oom_killed`, `memory_limit`) for lifecycle status queries, and
  `ExecutionRunners::Base#status` SHALL return it so callers classify a
  workload as `:running | :exited | :oom_killed | :not_found` without reaching
  into Docker API response shapes. `LocalDockerRunner#status` SHALL translate
  `Containers::Provision#container_status` (running, exit code, OOM flag,
  memory limit) into that object, mapping an unreachable environment to
  `:not_found`.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/base_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/containers/provision_spec.rb`
  *Code:* `ExecutionRunners::ExecutionStatus`,
  `ExecutionRunners::Base#status`,
  `ExecutionRunners::LocalDockerRunner#status`,
  `Containers::Provision#container_status`

- [x] **CONTAINER-RUNTIME-016** — When a Temporal activity retries after a
  worker restart or failover, the system SHALL load the persisted
  `RunnerHandle` from the `agent_runs.runner_handle` column and call
  `runner.reconnect(handle:)` / `runner.running?(handle:)` to decide whether to
  reuse a still-running environment or clean up a dead/missing one before
  provisioning fresh. Recovery SHALL work for all states: running (reuse), dead
  (cleanup + reprovision), and missing (no error, clean state, reprovision).
  A data migration SHALL populate `runner_handle` from existing `container_id` +
  `container_host` so legacy rows are recoverable immediately. The
  `runner_handle` column SHALL also be addable to `container_pool_entries` and
  `service_containers` so pool entries and service containers can store runner
  handles.
  *Tests:* `spec/models/agent_run_spec.rb`,
  `spec/migrations/add_runner_handle_to_execution_tables_spec.rb`
  *Code:* `AgentRun#provision_via_runner`, `AgentRun#reuse_or_reconcile_via_runner`

- [x] **CONTAINER-RUNTIME-017** — The system SHALL isolate networking policy
  from Docker network implementation by carrying an
  `ExecutionRunners::NetworkingPolicy` (mode `:proxy_restricted`,
  `:subscription_auth`, or `:direct_outbound`; `firewall?` predicate;
  `allow_destinations` array) on `RunSpec` and translating it to Docker
  network + firewall operations only inside `LocalDockerRunner`. A
  `proxy_restricted` policy SHALL map to the restricted Docker network plus
  in-container iptables firewall; `subscription_auth` and `direct_outbound`
  SHALL map to the infrastructure Docker network with no firewall. Proxy URL
  resolution SHALL accept the policy's `restricted?` predicate instead of a
  Docker network name, and `Containers::Provision` SHALL consume the policy
  via a `networking_policy:` constructor argument so the agent-run container
  decision flows from the runner rather than from inside the provisioner.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/execution_runners_spec.rb`,
  `spec/services/containers/proxy_url_spec.rb`,
  `spec/services/containers/provision_spec.rb`,
  `spec/services/network_policy_spec.rb`
  *Code:* `ExecutionRunners::NetworkingPolicy`,
  `ExecutionRunners::LocalDockerRunner`,
  `Containers::Provision.networking_policy_for`,
  `Containers::ProxyUrl.resolve`

- [x] **CONTAINER-RUNTIME-018** — The system SHALL define provider-neutral
  remote-execution manifests for the control-plane/runner boundary:
  `ExecutionInputManifest` (derived from `RunSpec`) and
  `ExecutionOutputManifest` (derived from `ExecutionResult` + `AgentRun`).
  The input manifest SHALL carry repository/ref, execution spec,
  prompt/context references, service declarations, and explicit lane refs for
  Git, control-plane API, object storage, and credentials. The output manifest
  SHALL carry result summaries, log references, verification results, durable
  binary artifact references, and git output identity, and SHALL distinguish
  code outputs from durable binary artifacts and structured results. Secret
  values SHALL be excluded by construction: credential lanes and service
  declarations may carry only identifiers or env keys, never secret payloads
  or host paths.
  *Tests:* `spec/services/execution_runners_spec.rb`
  *Code:* `ExecutionRunners::ExecutionInputManifest`,
  `ExecutionRunners::ExecutionOutputManifest`,
  `ExecutionRunners::RunSpec#input_manifest`,
  `ExecutionRunners::ExecutionResult#output_manifest`

- [x] **CONTAINER-RUNTIME-019** — The system SHALL provide a provider-neutral
  runner conformance suite that drives the complete normal create-PR
  lifecycle — clone, run, log capture, artifact output, result manifest, and
  cleanup — through the `ExecutionRunners` contract with no host-path
  assumptions, deriving its `RunSpec` via `RunSpec.from_agent_run` so every
  runner conforms to the same canonical scenario. The suite SHALL fail a
  runner that requires shared host storage: provisioning the host-path-free
  scenario must succeed, and the persisted `RunnerHandle` plus the input and
  output manifests SHALL carry no host filesystem paths. The suite SHALL
  verify Git is the only code transport (input-manifest Git lane with a
  declarative workspace carrying no host reference) and that durable outputs
  travel on the object-storage and control-plane API lanes. The runner
  contract surface (interface methods, parameters, and value-object members)
  SHALL NOT reference Docker `exec`, bind mounts, shared directories, or
  host-visible workspace paths. `LocalDockerRunner` SHALL pass the suite as
  the baseline without weakening local Docker development (legacy bind-mount
  runs remain a compatibility path outside the conformance scenario), and
  negative controls SHALL prove the suite rejects host-storage-requiring
  runners, handles, manifests, and contract surfaces.
  *Tests:* `spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`
  *Code:* `spec/support/no_shared_filesystem_conformance.rb`,
  `spec/support/shared_examples/no_shared_filesystem_conformance.rb`
