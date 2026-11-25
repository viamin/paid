# EARS Specs: Isolated Rust SDK Build Environment

> Testable claims for the architecture-compatible isolated Rust/SDK build
> environment capability, per `docs/intent/isolated-rust-sdk-build/isolated-rust-sdk-build-design.md`
> and issue #5358. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r RUST-SDK-BUILD-001`).

- [x] **RUST-SDK-BUILD-001** — When an architecture alias
  (`x86_64`, `x64`, `aarch64`, `arm64`, `armv7l`, `armhf`) is normalized,
  the system SHALL map it to its OCI architecture name (`amd64`, `arm64`,
  `arm`) and SHALL map an unrecognized value to `nil` rather than
  guessing.
  *Tests:* `spec/services/sdk_build_environments/architecture_compatibility_spec.rb`.
  *Code:* `SdkBuildEnvironments::ArchitectureCompatibility.normalize`.

- [x] **RUST-SDK-BUILD-002** — When an ELF interpreter path is presented
  (`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`, Debian
  multiarch resolved paths), the system SHALL derive the architecture
  that path implies and SHALL return `nil` for a path implying none.
  *Tests:* `spec/services/sdk_build_environments/architecture_compatibility_spec.rb`.
  *Code:* `SdkBuildEnvironments::ArchitectureCompatibility.interpreter_architecture`.

- [x] **RUST-SDK-BUILD-003** — When a toolchain binary's interpreter
  architecture differs from the runner's normalized process architecture,
  the system SHALL classify the observation as an architecture mismatch
  naming both the binary's and the runner's architecture, and SHALL NOT
  classify it as a host configuration problem.
  *Tests:* `spec/services/sdk_build_environments/architecture_compatibility_spec.rb`.
  *Code:* `SdkBuildEnvironments::ArchitectureCompatibility.classify_toolchain`.

- [x] **RUST-SDK-BUILD-004** — When container output contains a dynamic
  loader failure (`Dynamic loader not found: <interpreter path>`), the
  system SHALL attribute the requested loader architecture to the path,
  classify it as foreign only when the known process architecture differs,
  and identify a matching architecture's missing loader separately. Unknown
  loader or process architectures SHALL remain unknown; the signature alone
  SHALL NOT establish the historical runner or downloaded artifact's cause.
  It SHALL return no classification when the output carries no such signature.
  *Tests:* `spec/services/sdk_build_environments/architecture_compatibility_spec.rb`.
  *Code:* `SdkBuildEnvironments::ArchitectureCompatibility.classify_loader_failure`.

- [x] **RUST-SDK-BUILD-005** — When the pinned recipe is loaded, every
  toolchain image reference SHALL carry an architecture-qualified
  immutable digest, every checksummed artifact (protoc, libclang) SHALL
  carry a SHA-256 value, and every source pin (SDK commit, Core commit,
  Cargo.lock digest) SHALL be a full-length hex SHA, so no recipe member
  can silently degrade to a mutable or truncated identity.
  *Tests:* `spec/services/sdk_build_environments/pins_spec.rb`.
  *Code:* `SdkBuildEnvironments::Pins`.

- [x] **RUST-SDK-BUILD-006** — When the recipe is resolved for an
  architecture it supports, the system SHALL return the complete pin set
  for that architecture; when resolved for an unsupported architecture,
  it SHALL raise a named error naming the supported set rather than
  returning a partial recipe.
  *Tests:* `spec/services/sdk_build_environments/pins_spec.rb`.
  *Code:* `SdkBuildEnvironments::Pins.for_architecture`.

- [x] **RUST-SDK-BUILD-007** — When the recipe is inspected, it SHALL
  distinguish the Core development toolchain pin (1.95.0) from the crate
  MSRV floor (1.88.0) and SHALL record the target Ruby build profile
  (version, extension API, shared/static linkage), so build evidence
  states which profile it proves.
  *Tests:* `spec/services/sdk_build_environments/pins_spec.rb`.
  *Code:* `SdkBuildEnvironments::Pins`.

- [x] **RUST-SDK-BUILD-008** — When preflight runs against collected
  facts, the receipt SHALL record the backend identifier, engine
  architecture, image identity (reference, digest, platform), process
  architecture, and each resolved toolchain path with its ELF
  architecture, interpreter, and execution status — and SHALL contain no credential
  material.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`.

- [x] **RUST-SDK-BUILD-009** — When the engine architecture, image
  architecture, and observed process architecture disagree, or the image
  or process architecture is absent, the
  preflight verdict SHALL be a named failure
  (`image_architecture_mismatch`, `process_architecture_mismatch`, or an
  unverifiable architecture verdict)
  with a remediation hint, and SHALL NOT be `compatible`.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`.

- [x] **RUST-SDK-BUILD-010** — When the metadata probe fails, reports no
  `cargo` or `rustc` inventory, a required toolchain binary is absent from the
  environment's default PATH, `cargo --version` or `rustc --version` exits
  non-zero, or its interpreter architecture mismatches the process
  architecture, the preflight verdict SHALL be a named failure
  (`unverifiable`, `toolchain_absent`, `toolchain_unusable`, or
  `loader_architecture_mismatch`) with a
  remediation hint, and SHALL NOT be `compatible`. Metadata probing SHALL
  NOT pull or build images; an unavailable image SHALL produce unverifiable
  facts without provisioning it.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`,
  `spec/services/sdk_build_environments/metadata_probe_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`, `SdkBuildEnvironments::MetadataProbe`.

- [x] **RUST-SDK-BUILD-011** — When the rake task
  `sdk_build_environment:preflight` runs, it SHALL execute the same
  classification as the service against a real backend and SHALL emit the
  receipt as JSON, provisioning no build containers and mutating no run,
  worker, or pin state. Any disposable metadata-probe container SHALL obey
  RUST-SDK-BUILD-012 and be cleaned up.
  *Tests:* `spec/tasks/sdk_build_environment_preflight_rake_spec.rb`.
  *Code:* `lib/tasks/sdk_build_environment.rake`.

- [x] **RUST-SDK-BUILD-012** — When the metadata probe's disposable
  container requirements are handed to a backend, every isolation
  requirement SHALL be enforced by that backend or rejected before the
  container starts: read-only root filesystem and direct CPU limits
  expressed in Engine `HostConfig` form SHALL survive the Swarm
  service-spec translation, and a backend that cannot enforce a
  network-disabled container (the Swarm service API has no equivalent —
  a service with no network attachments lands its task on the node's
  default bridge network) SHALL be refused before any probe container is
  created, the receipt recording the refusal as a probe failure naming
  the backend, and the Swarm translation SHALL raise a named error for
  configs requesting `NetworkDisabled` instead of silently dropping it.
  *Tests:* `spec/services/sdk_build_environments/metadata_probe_spec.rb`,
  `spec/services/containers/backends/swarm_spec.rb`.
  *Code:* `SdkBuildEnvironments::MetadataProbe`,
  `Containers::Backends::Base#supports_network_disabled_containers?`,
  `Containers::Backends::Swarm`.
