# EARS Specs: Immutable Runtime Images

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **IMMUTABLE-IMAGE-001** — When a production agent execution requests a
  runtime image profile/tag, the system SHALL resolve that request to an
  immutable digest reference before provisioning the container.
  *Code:* `app/services/containers/runtime_image_selector.rb`,
  `app/services/containers/runtime_image_catalog.rb`,
  `app/services/containers/provision.rb`,
  `app/services/execution_runners.rb` (`RunSpec.from_agent_run`).
  *Test:* `spec/services/containers/runtime_image_selector_spec.rb`,
  `spec/services/containers/provision_spec.rb`,
  `spec/services/execution_runners_spec.rb`.

- [x] **IMMUTABLE-IMAGE-002** — When a run selects its final runtime image, the
  system SHALL persist the requested image, resolved image, digest,
  architecture, registry, repository, and provenance reference on the run.
  Warm-pool claims SHALL persist the warm-time selection of the claimed
  container, not a later re-resolution of the catalog default. Non-pool
  reconnects SHALL reuse the selection already recorded on the run rather
  than overwriting provenance with a fresh catalog resolution, and a
  replacement container provisioned from scratch SHALL clear the recorded
  selection so the current catalog default is recorded on the new container.
  Building a provider-neutral `RunSpec` for a fresh (non-pooled) provision
  SHALL follow the same reuse-or-resolve rule as `Containers::Provision`, so
  a `RunSpec` rebuilt for a retry never disagrees with the selection already
  recorded on the run.
  *Code:* `app/models/agent_run.rb`,
  `app/models/container_pool_entry.rb`,
  `app/services/containers/provision.rb`,
  `app/services/containers/pool_manager.rb`,
  `app/services/execution_runners.rb` (`RunSpec.from_agent_run`).
  *Test:* `spec/models/agent_run_runtime_image_spec.rb`,
  `spec/services/containers/provision_spec.rb`,
  `spec/services/containers/pool_manager_spec.rb`,
  `spec/services/execution_runners_spec.rb`.

- [x] **IMMUTABLE-IMAGE-003** — When running in local development/test, the
  system SHALL continue allowing mutable tags such as `paid-agent:latest`
  without forcing immutable digests.
  *Code:* `app/services/containers/runtime_image_selector.rb`.
  *Test:* `spec/services/containers/runtime_image_selector_spec.rb`.

- [x] **IMMUTABLE-IMAGE-004** — When a production run attempts to select a
  blocked or deprecated runtime image identity, the system SHALL reject that
  selection for new runs.
  *Code:* `app/services/containers/runtime_image_catalog.rb`,
  `app/services/containers/runtime_image_selector.rb`.
  *Test:* `spec/services/containers/runtime_image_selector_spec.rb`.

- [x] **IMMUTABLE-IMAGE-005** — When an operator requests rollback to a prior
  active digest, the system SHALL allow that provenance reference without
  changing the default mutable tag authority.
  *Code:* `app/services/containers/runtime_image_catalog.rb`,
  `app/services/containers/runtime_image_selector.rb`.
  *Test:* `spec/services/containers/runtime_image_selector_spec.rb`.

- [x] **IMMUTABLE-IMAGE-006** — The provider-neutral `RunSpec` built for a
  container execution SHALL carry the resolved runtime image selection
  (requested image, resolved image, digest, architecture, registry,
  repository, provenance reference, and immutability flag) as a first-class
  field, and the `ExecutionInputManifest` derived from that `RunSpec` SHALL
  expose the same selection under `execution["runtime_image"]`, so any
  runner — and runner conformance suites — can inspect the resolved image
  identity without depending on Docker-specific `Containers::Provision`
  internals.
  *Code:* `app/services/execution_runners.rb` (`RunSpec#runtime_image_selection`,
  `ExecutionInputManifest.from_run_spec`).
  *Test:* `spec/services/execution_runners_spec.rb`.
