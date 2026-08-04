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
