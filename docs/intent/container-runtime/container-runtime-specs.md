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
  code outputs from durable binary artifacts and structured results. Durable
  binary artifact references SHALL include content type, object-storage key
  and/or URL, and run context (`account_id`, `project_id`, `agent_run_id`).
  Artifact manifests persisted as durable records on the run (e.g.
  `AgentRun#external_metadata["artifact_manifest"]`) SHALL carry storage keys
  without presigned URLs — presigned URLs expire within the SigV4 one-week cap
  and are ephemeral, so durable consumers re-sign from the key. The output
  manifest's binary artifact references SHALL distinguish trusted source lanes
  from agent-authored ones: artifacts from
  `AgentRun#external_metadata["artifact_manifest"]` (persisted by the runner,
  or by interop ingestion — `Api::Projects::ExternalAgentRunsController`
  persists caller-supplied `external_metadata` verbatim via
  `AgentRuns::IngestExternal`) have their storage keys honored only when the
  key lives under the project's own storage namespace
  (`Screenshots::Storage.namespace_prefix`, i.e. `screenshots/<owner>/<repo>/`);
  any other key degrades to URL-only. Artifacts from
  `AgentRun#verification_result["artifacts"]` (written by the agent inside the
  container and persisted as-is by
  `AgentRuns::VerificationResultRecorder`) are untrusted input — only `url`
  survives so a spoofed key under another tenant's prefix cannot be re-signed
  into a working presigned URL by a durable consumer. The run's
  `account_id`, `project_id`, and `agent_run_id` SHALL always be the
  authoritative context (the system already knows the real identity), so an
  artifact-supplied context value can never override the run's identity.
  Secret values SHALL be excluded by construction: credential lanes and
  service declarations may carry only identifiers or env keys, never secret
  payloads or host paths.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/screenshots/container_capture_spec.rb`
  *Code:* `ExecutionRunners::ExecutionInputManifest`,
  `ExecutionRunners::ExecutionOutputManifest`,
  `ExecutionRunners::RunSpec#input_manifest`,
  `ExecutionRunners::ExecutionResult#output_manifest`,
  `ExecutionRunners::ExecutionOutputManifest.build_binary_artifact_refs`

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
  travel on the object-storage and control-plane API lanes. Logs SHALL cross
  the runner boundary as streamed stdout/stderr chunks yielded through the
  `ExecutionRunners::Base#start` block rather than through shared host files.
  The runner contract surface (interface methods, parameters, and value-object
  members) SHALL NOT reference Docker `exec`, bind mounts, shared directories,
  or host-visible workspace paths. `LocalDockerRunner` SHALL pass the suite as
  the baseline without weakening local Docker development (legacy bind-mount
  runs remain a compatibility path outside the conformance scenario), and
  negative controls SHALL prove the suite rejects host-storage-requiring
  runners, handles, manifests, streamed output plumbing, and contract
  surfaces.
  *Tests:* `spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/containers/provision_spec.rb`
  *Code:* `app/services/containers/provision.rb`,
  `app/services/execution_runners/base.rb`,
  `app/services/execution_runners/local_docker_runner.rb`,
  `spec/support/no_shared_filesystem_conformance.rb`,
  `spec/support/shared_examples/no_shared_filesystem_conformance.rb`

- [x] **CONTAINER-RUNTIME-020** — The system SHALL carry an
  `ExecutionRunners::NetworkingPolicy#egress_profile` value (`:locked` (default
  for production), `:research`, or `:open`) through `RunSpec` and the
  `ExecutionInputManifest#networking` section so orchestration code can request
  a per-run egress posture without referencing Docker network names, iptables
  rules, or gateway implementation details. The factory methods
  `proxy_restricted`, `subscription_auth`, and `direct_outbound` SHALL default
  the profile to `:locked`; `:research` and `:open` SHALL be selectable via the
  same factory methods. The profile SHALL be exposed via `locked?`, `research?`,
  and `open?` predicates on `NetworkingPolicy` so future enforcement adapters
  can reject unsupported production runs without inspecting implementation
  details. The runner contract surface (interface methods, parameters, and
  value-object members) SHALL remain free of Docker `exec`, bind mounts,
  shared directories, and host-visible workspace paths, and the
  `ExecutionInputManifest`'s networking section SHALL NOT serialize Docker
  bridge names, internal network names, or iptables syntax.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/containers/provision_spec.rb`
  *Code:* `ExecutionRunners::NetworkingPolicy`,
  `ExecutionRunners::ExecutionInputManifest`,
  `ExecutionRunners::RunSpec`,
  `Containers::Provision.networking_policy_for`

- [x] **CONTAINER-RUNTIME-025** — When an execution runner provisions a
  resource whose kind it can identify (`#resource_kind` present), the system
  SHALL create a provisioning-intent ledger row (status `pending`) recording
  the runner type, resource kind, environment, account, project, run, attempt,
  and ownership tags BEFORE the runner issues the provider create call. When the
  provider create call succeeds, the system SHALL capture the provider resource
  identifier on the ledger row (status `created`), and when the runner builds
  the handle it SHALL link the serialized runner handle to the ledger row
  (status `linked`). A runner that cannot identify a resource kind SHALL
  provision without recording a ledger row.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/models/provisioning_intent_spec.rb`,
  `spec/support/shared_examples/execution_runner_contract.rb`
  *Code:* `ExecutionRunners::ProvisioningLedger`,
  `ExecutionRunners::LocalDockerRunner#provision`, `ProvisioningIntent`

- [x] **CONTAINER-RUNTIME-026** — When a runner provisions a resource it SHALL
  apply the stable Paid ownership tags — environment, account, project, run,
  attempt, and resource kind — to the provider resource (Docker labels for the
  Docker runner) so an orphaned resource can be attributed back to its Paid
  origin. When a runner or provider cannot apply tags or list resources
  (`#supports_tagging?` / `#supports_listing?` false), the system SHALL degrade
  explicitly: record the unsupported capability on the ledger row and emit a
  warning instead of failing provisioning.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/support/shared_examples/execution_runner_contract.rb`
  *Code:* `ExecutionRunners::OwnershipTags`,
  `ExecutionRunners::LocalDockerRunner#provision`,
  `Containers::Provision#container_labels`

- [x] **CONTAINER-RUNTIME-027** — When a crash occurs after the provider create
  call returns a resource identifier but before the runner handle is persisted,
  the system SHALL leave enough information for reconciliation: a
  provisioning-intent ledger row in the `created` state carrying the provider
  resource identifier, plus the ownership tags applied to the live resource.
  Reconciliation SHALL be able to locate the orphaned resource by ledger row or
  by ownership tag without the persisted runner handle.
  *Tests:* `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/models/provisioning_intent_spec.rb`
  *Code:* `ExecutionRunners::ProvisioningLedger`,
  `ProvisioningIntent`
- [x] **CONTAINER-RUNTIME-021** — The system SHALL persist an `AgentImage`
  registry record that represents the immutable production identity of an
  agent container image as `(account_id, registry, repository, digest,
  architecture)`. Identity fields (`name`, `tag`, `registry`, `repository`,
  `digest`, `architecture`, `account_id`, `built_at`) SHALL be immutable after
  creation: a new build produces a new digest, which is a new row. The digest
  SHALL be accepted as a 64-character hex sha256, optionally prefixed with
  `sha256:`, and SHALL be stored canonicalized as `sha256:<hex>` so both input
  forms resolve to one identity and every emitted reference is a valid OCI
  digest reference.
  Local development and single-backend deployments SHALL continue to use the
  literal `paid-agent:latest` reference; the registry is the system of record
  for what image actually runs in production, not the
  `Containers::ImageResolver::BASE_IMAGE` constant.
  *Tests:* `spec/models/agent_image_spec.rb`
  *Code:* `AgentImage`

- [x] **CONTAINER-RUNTIME-022** — The `AgentImage` record SHALL support a
  status state machine with three values: `active` (schedulable),
  `deprecated` (still runnable but superseded, retained for rollback), and
  `blocked` (excluded from future scheduling, retained for audit and to
  explain prior run outcomes). Transitions SHALL be idempotent:
  `active -> deprecated -> blocked` and `active -> blocked` are allowed,
  re-applying the same transition SHALL NOT re-stamp the timestamp or
  replace the recorded reason. The `AgentImage` record SHALL never be
  deleted; historical records are retained for audit and rollback.
  *Tests:* `spec/models/agent_image_spec.rb`
  *Code:* `AgentImage#deprecate!`, `AgentImage#block!`, `AgentImage#schedulable?`

- [x] **CONTAINER-RUNTIME-023** — The `AgentImage` registry SHALL enforce
  uniqueness on the immutable production identity `(account_id, registry,
  repository, digest, architecture)`. The same digest on a different
  architecture SHALL be a separate image record (multi-arch images are
  registered as one row per architecture). The same identity MAY be
  recorded independently by different accounts. The `provenance` and
  `metadata` jsonb fields SHALL be mutable so late-arriving build
  metadata and runbook links can be added without affecting the
  immutable identity, and their changes SHALL be tracked (logidze) so mutable
  provenance/metadata edits and lifecycle transitions leave an audit trail of
  who changed what and when.
  *Tests:* `spec/models/agent_image_spec.rb`
  *Code:* `AgentImage`, `idx_agent_images_identity`

- [x] **CONTAINER-RUNTIME-024** — The `AgentImage` record SHALL expose
  scheduling-relevant query scopes: `AgentImage.active` /
  `AgentImage.schedulable` (only `active` rows), `AgentImage.deprecated`,
  `AgentImage.blocked`, and `AgentImage.historical` (the
  `deprecated`+`blocked` union for audit and rollback). A partial index
  over non-active rows SHALL keep audit queries fast as the active set
  grows, and a `(account_id, name, architecture)` lookup index SHALL
  support the (profile, architecture) scheduling decision.
  *Tests:* `spec/models/agent_image_spec.rb`
  *Code:* `AgentImage.active`, `AgentImage.schedulable`,
  `AgentImage.historical`, `idx_agent_images_inactive`,
  `idx_agent_images_profile_arch`

- [x] **CONTAINER-RUNTIME-025** — Capacity admission SHALL enforce aggregate
  requested CPU, memory, and disk ceilings globally and per selected backend,
  using provider-neutral execution resource specs rather than Docker-only
  fields, and SHALL return a named denial reason naming the constrained scope
  and resource dimension.
  *Tests:* `spec/services/capacity/run_admission_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/services/metrics/prometheus_collector_spec.rb`
  *Code:* `Capacity::RunAdmission`, `Capacity::RequestedResources`,
  `Capacity::InfrastructureLimits`, `Metrics::PrometheusCollector`

- [x] **CONTAINER-RUNTIME-026** — Capacity admission SHALL enforce global,
  per-account, and per-project provisioning-rate limits over a configured time
  window, returning a named denial reason and a next-eligible timestamp so the
  queue can park the run until the limit window opens again.
  *Tests:* `spec/services/capacity/run_admission_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`
  *Code:* `Capacity::RunAdmission`, `Capacity::ProvisioningRateWindow`,
  `ProcessRunQueueJob`

- [x] **CONTAINER-RUNTIME-027** — The provider-neutral execution resource spec
  SHALL include CPU, memory, and disk request fields, and the system SHALL
  reject a run whose requested per-execution resources exceed the configured
  infrastructure maxima before provisioning starts.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/capacity/run_admission_spec.rb`
  *Code:* `ExecutionRunners::ComputeRequirements`,
  `ExecutionRunners::RunSpec`, `Capacity::RunAdmission`

- [x] **CONTAINER-RUNTIME-028** — The system SHALL expose a coarse,
  provider-neutral networking intent vocabulary on
  `ExecutionRunners::NetworkingPolicy` with six intents:
  `:no_outbound` (air-gapped; loopback + DNS only),
  `:proxy_only` (Paid secrets proxy + DNS),
  `:git_plus_proxy` (adds GitHub CIDR ranges),
  `:approved_services` (adds service container IPs — the default
  restricted behavior for API-key LLM runs),
  `:model_direct` (provider CLI reaches upstream APIs), and
  `:explicit_internet` (operator opt-in full egress). The three legacy
  factories (`:proxy_restricted`, `:subscription_auth`, `:direct_outbound`)
  SHALL remain valid constructors and normalize to their canonical
  intent via `#canonical_mode`. `LocalDockerRunner` SHALL translate each
  intent to a Docker network + firewall shape that matches the RDR-062
  mapping table (`:no_outbound` omits both proxy and GitHub allow rules;
  `:proxy_only` allows the proxy but not GitHub; `:approved_services` is
  the previous restricted behavior; the two unrestricted intents use the
  infrastructure Docker network with no firewall). The abstract
  `ExecutionRunners::Base` SHALL declare `supports_policy?(policy)` so a
  concrete runner can advertise which intents its native egress primitives
  can implement, and `LocalDockerRunner.compatible?` SHALL call
  `supports_policy?` to reject unsupported specs before any provision
  attempt. `ExecutionRunners::ContractRunner` SHALL provide a configurable
  in-memory implementation whose supported intent set is declared at the
  class level (narrowed via the `ContractRunner.supporting` factory, which
  returns a subclass) so `.supports_policy?`, `.compatible?`, and
  `#provision` all consult the same source and the runner contract specs
  can assert that capability mismatches surface in `.compatible?` rather
  than silently downgrading.
  *Tests:* `spec/services/execution_runners_spec.rb`,
  `spec/services/execution_runners/base_spec.rb`,
  `spec/services/execution_runners/local_docker_runner_spec.rb`,
  `spec/services/execution_runners/contract_runner_spec.rb`,
  `spec/services/network_policy_spec.rb`,
  `spec/services/containers/proxy_url_spec.rb`
  *Code:* `ExecutionRunners::NetworkingPolicy`,
  `ExecutionRunners::Base`,
  `ExecutionRunners::LocalDockerRunner`,
  `ExecutionRunners::ContractRunner`,
  `NetworkPolicy.apply_firewall_rules`,
  `NetworkPolicy.build_firewall_script`,
  `NetworkPolicy.contract_for_policy`,
  `Containers::ProxyUrl.resolve`

- [x] **CONTAINER-RUNTIME-029** — When a container is provisioned for a run
  that may use an OpenCode-engine CLI (OpenCode, or its fork Kilocode), the
  system SHALL size that CLI's data tmpfs (`/home/agent/.local/share/opencode`
  / `/home/agent/.local/share/kilo`) at 256MB so a long agent attempt's
  SQLite state (db + WAL) and file snapshots do not exhaust it — once the
  tmpfs is full, every subsequent CLI start in that container fails at
  startup on `PRAGMA wal_checkpoint` (tmpfs ENOSPC; reproduced for both
  CLIs against `paid-agent:latest`).
  *Tests:* `spec/services/containers/provision_spec.rb`.
  *Code:* `Containers::Provision` tmpfs configuration.

- [x] **CONTAINER-RUNTIME-030** — When a contract-owned CLI install block in
  the agent image fails a post-install Oh My Pi assertion, the Dockerfile
  SHALL identify which check failed and print enough local diagnostic state to
  act on the failure without rerunning interactively. For the Oh My Pi block,
  the image SHALL distinguish: missing `omp` on `PATH`, a non-executable `omp`
  launcher, and a Bun version mismatch after install.
  *Tests:* `spec/config/agent_image_build_script_spec.rb`.
  *Code:* `docker/agent/Dockerfile`.
