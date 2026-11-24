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
  system SHALL classify it as foreign-architecture binary execution
  attributed to the interpreter path's implied architecture, and SHALL
  return no classification when the output carries no such signature.
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
  architecture and interpreter — and SHALL contain no credential
  material.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`.

- [x] **RUST-SDK-BUILD-009** — When the engine architecture and the
  image architecture disagree, or the image architecture is absent, the
  preflight verdict SHALL be a named failure
  (`image_architecture_mismatch` / `unverifiable_image_architecture`)
  with a remediation hint, and SHALL NOT be `compatible`.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`.

- [x] **RUST-SDK-BUILD-010** — When a toolchain binary is absent from the
  environment's default PATH, or its interpreter architecture mismatches
  the process architecture, the preflight verdict SHALL be a named
  failure (`toolchain_absent` / `loader_architecture_mismatch`) with a
  remediation hint, and SHALL NOT be `compatible`.
  *Tests:* `spec/services/sdk_build_environments/preflight_spec.rb`.
  *Code:* `SdkBuildEnvironments::Preflight`.

- [x] **RUST-SDK-BUILD-011** — When the rake task
  `sdk_build_environment:preflight` runs, it SHALL execute the same
  classification as the service against a real backend and SHALL emit the
  receipt as JSON, provisioning no containers and mutating no run,
  worker, or pin state.
  *Tests:* `spec/tasks/sdk_build_environment_preflight_rake_spec.rb`.
  *Code:* `lib/tasks/sdk_build_environment.rake`.
