---
parent: PAID
prefix: RUST-SDK-BUILD
---

# Low-Level Design: Isolated Rust SDK Build Environment

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the environment capability for version-bound Rust SDK
> builds in isolated containers: architecture-compatibility classification,
> the pinned build recipe, and the preflight receipt collected before any
> build container is provisioned. It exists because of issue #5358: an
> agent attempted Rust SDK work on an ARM64 runner, found no cargo in the
> agent image, installed a toolchain ad hoc, and hit
> `Dynamic loader not found: /lib64/ld-linux-x86-64.so.2` while reporting
> an aarch64 host. The original process and downloaded artifact were not
> independently measured. The historical container
> and its mutable-tag image are gone, so the original provisioning failure
> cannot be reproduced; Paid provides a supported path with measured
> profiles, explicit artifact identities and bounded command outcomes.

## Purpose

Give the SDK prototype owner (#5326) an independently runnable,
reproducible preflight prerequisite for Rust/SDK builds in Paid's supported
execution environment — Docker-backed containers with digest-pinned,
architecture-matched toolchain images — without touching host or
control-plane SDK pins, operating workers, or the agent image. The delivered
capability includes the version-bound Core baseline through the existing
isolated job shell, including for automatic owners without MCP access.
Prototype changes, native-artifact loading and SDK/server acceptance remain
with #5326; metadata classification alone is not build evidence.

## Scope boundaries

- **Environment capability only.** The Core/Ruby prototype, the
  finite-attempt harness, and any client/server workflow tests belong to
  #5326. This segment provides the environment: pins, preflight, the runnable
  job-local Core baseline, and classification of loader/architecture failures.
- **No runtime pin changes.** The recipe lives in versioned data in this
  segment's module. It is not wired into `bin/update`, the agent image
  build, or the combo-image language layers
  (`docs/intent/toolchain-pin-management/` owns those). Nothing here
  changes the `paid-agent` base image or any operating runner.
- **No publication or rollout.** Recipe images are referenced by digest
  for private, disposable build containers. Nothing here publishes an
  image, stops a worker, or resets native-attempt budgets.

## Architecture-compatibility classification

The reported failure is a class, not a one-off: a dynamically linked
binary records its interpreter path in the ELF program header, and the
kernel refuses to exec it when that loader is absent. The GNU/Linux
glibc toolchains use `/lib64/ld-linux-x86-64.so.2` for x86-64 and
`/lib/ld-linux-aarch64.so.1` for aarch64. When the selected environment
lacks that interpreter, execution fails.
The named path is evidence about the requested loader, not independent
proof of the historical host, image contents, or downloaded artifact.
The original container and artifact were not retained; an architecture
mismatch is a diagnosis to test against actual process and ELF metadata,
not an established cause of that historical attempt.

`SdkBuildEnvironments::ArchitectureCompatibility` owns this mapping:

- normalize architecture aliases (`x86_64`/`x64` → `amd64`,
  `aarch64`/`arm64` → `arm64`, `armv7l`/`armhf` → `arm`);
- derive the architecture an ELF interpreter path implies, including
  Debian multiarch resolved paths
  (`/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1`);
- classify an observed toolchain against the runner architecture as
  `:compatible`, `:architecture_mismatch`, or `:unknown`, with the
  mismatch naming both sides;
- recognize the reported failure signature from container output so a
  raw `Dynamic loader not found: <path>` line is classified as a
  foreign-architecture binary execution, attributed to the loader path's
  architecture, never to the runner.

## The pinned recipe

Root's independently verified probes (2026-11-24, receipts referenced in
issue #5358) established an architecture-matched recipe. It is recorded
here as frozen data in `SdkBuildEnvironments::Pins`, keyed by
architecture, with every member carrying its evidence source:

| Member | Value (linux/arm64) |
| --- | --- |
| Toolchain image (Core dev pin) | `rust:1.95.0-bookworm`, repo digest `sha256:6258907a…d4a1`, image id `sha256:7cf1e580…3977` |
| MSRV-floor image | `rust:1.88.0-bookworm`, repo digest `sha256:af306cfa…bfe0`, image id `sha256:9ad0c47…436e` |
| protoc | 34.0, `protoc-34.0-linux-aarch_64.zip`, asset `sha256:f0b8aad2…e6c8` |
| libclang | Ubuntu `1:18.1.3-1ubuntu1` (arm64) set; installed `libclang.so.1` `sha256:be2902f4…0a4` |
| Ruby SDK source | `61db6dd4b75e3b15731e58f26934b33c17663237` (v1.11.0) |
| Core submodule | `c675c32469af707e1c979a7b808c70b4a0608b82` |
| Cargo.lock | `47aba453a6f46d71b5deba2d09e1e6b9ef036cc5ba7263562793205e142bc9aa` |
| Ruby build profile | 3.4.13, extension API `3.4.0-static`, `ENABLE_SHARED=no` (actual agent image) |

Two non-obvious facts the pins preserve:

- The Core crate's MSRV (1.88) is *not* its development pin; the checked-in
  `rust-toolchain.toml` specifies 1.95, and only 1.95 compiled the exact
  locked source. The MSRV-floor image is recorded for classification, not
  as the build toolchain.
- A build for the agent image's static Ruby (`ENABLE_SHARED=no`) is not
  interchangeable with a shared-Ruby host build: native gems compiled
  against one profile do not load under the other. The recipe records the
  profile alongside the pins so load evidence states which profile it
  proves.

## Preflight before provisioning

Before any build container is provisioned, the capability captures a
sanitized receipt (`SdkBuildEnvironments::Preflight`): backend/engine
identity and architecture, the selected image's id, digest, and platform,
the actual process architecture observed in the image, resolved
cargo/rustc paths, each toolchain binary's ELF architecture and
interpreter path, and the exit statuses of `cargo --version` and
`rustc --version`. The receipt carries a check-based verdict —
`compatible`, or a named failure (`image_architecture_mismatch`,
`toolchain_absent`, `toolchain_unusable`, `loader_architecture_mismatch`,
`unverifiable`) with
a remediation hint — so an unsupported pairing fails loudly before
Cargo ever runs, instead of surfacing as a loader error inside a build
log.

The facts are collected through an injectable probe object so the
service runs under tests without a Docker daemon; the production probe
uses the backend API (`system_info`, image inspect, a disposable
metadata container with bounded resources and no network). Receipts are
metadata-only: commands and outcomes, never credential material.
The probe does not pull or build images. A selected image that is not
available yields unverifiable facts without hidden network provisioning;
the job-local recipe owns its explicitly bounded public-input preparation.

The disposable container's isolation contract is backend-enforced, not
advisory. Because the probe executes toolchain binaries from an
operator-selected image, the backend must be able to honor
`NetworkDisabled`; the probe asks
`Containers::Backends::Base#supports_network_disabled_containers?` and
refuses to start anything on a backend that cannot. The Swarm service
API is such a backend — its spec has no `NetworkDisabled` field, a
service with no network attachments lands its task on the node's
default bridge network, and the engine's predefined `none` network is
not a swarm-attachable network (the swarm store only exposes `bridge`
and `host`) — so `rake sdk_build_environment:preflight` under
`CONTAINER_BACKEND=swarm` yields an `unverifiable` receipt naming the
limitation instead of running the probe on the default network. The
Swarm translation also raises for a `NetworkDisabled` config rather
than silently dropping the flag, and it maps the Engine `HostConfig`
forms of the read-only root filesystem and the direct `NanoCpus` limit
into the service spec so those requirements survive translation too.

## Independent runnability

`rake sdk_build_environment:preflight` runs the same classification
against a real backend and prints the receipt as JSON. It performs
metadata probes only, creates only the bounded disposable probe described
above rather than a build environment, and requires no run, project,
or worker state — the environment prerequisite stays independently
runnable, per the issue's "no explicit dependency on #5326" constraint.

## Job-local baseline handoff

The existing SDK owner can also install an explicitly pinned toolchain
inside its isolated job-owned workspace without changing the agent image
or requiring a Docker socket. The [job-local baseline recipe](job-local-baseline/README.md)
contains the exact successful install, fetch and offline Core-check bodies,
public artifact URLs, checksums, source revisions and runtime profile.
Preparation is a single-use operation in the assigned physical `/workspace`:
before creating a recipe directory or downloading an artifact, it rejects a
different or symlinked root and every occupied or symlinked reserved path,
then atomically claims the preparation slot. This prevents an interrupted or
parallel attempt from overlaying untracked source or Cargo configuration onto
the pinned archive. The first exclusive directory creation claims preparation;
retained reserved paths make any retry fail closed. Ordinary checkout files
and an existing ordinary tools parent remain available to the job.
This is an environment baseline and a handoff to #5326, not evidence that
the Ruby bridge, server harness or task-safe quiescence contract passed.
The assigned job limits and canonical attempt history remain authoritative.

Public-input preparation requires the physical assigned `/workspace` directory,
which may already contain Paid and its Git metadata. Before creating anything
or invoking a downloader, it refuses occupied or symlinked recipe paths and a
symlinked `tools` parent. It claims the first reserved directory exclusively so
a repeated or concurrent preparation cannot overwrite the first attempt. An
incomplete preparation is retained for the normal owned-artifact lifecycle;
the script never deletes existing workspace contents to retry.

## Decisions & Alternatives

| Decision | Rationale | Alternatives rejected |
| --- | --- | --- |
| Classify the failure class, not reproduce it | The original container, its mutable-tag image, and the exact downloaded artifact are gone; manufacturing a reproduction would be fabrication. The classifier turns the recorded signature into actionable, testable diagnosis. | Re-running rustup install blindly and hoping to hit the same error; attributing the historical image content without evidence. |
| Frozen recipe data, not `bin/update` pins | The SDK build toolchain is job-scoped input for #5326's harness, not a Paid environment every agent image carries. Wiring it into the pin registry would change control-plane pin surface, which the issue forbids. | Adding Rust to the agent base image (host pin change, unrequested rollout); extending combo language layers (same problem at a different layer). |
| Digest-pinned official toolchain images | Root verified the official ARM64 images by immutable digest; mutable tags would reintroduce exactly the unmeasured-identity gap that made the historical failure undiagnosable. | Trusting `rust:latest`-style tags; vendoring a toolchain into the repo. |
| Injectable facts probe | Keeps classification hermetic and testable without a daemon, following the `AppleVerification::Setup::Shell` precedent. | Requiring a live daemon in unit tests; shelling out from the model layer. |
| Record Ruby build profile with the pins | The static/shared ABI gap silently invalidates cross-profile load claims (root's ABI control receipts). Recording it makes the limitation structural rather than tribal knowledge. | Treating "Ruby 3.4.13" as sufficient identity. |

## What this is not

- **Not the prototype's SDK/server harness.** Rails metadata/preflight code
  does not clone or build SDK source. The owner-executed job recipe does fetch
  the pinned source and compile its Core baseline; #5326 still owns prototype
  changes, native loading and its finite-attempt SDK/server harness.
- **Not a runner selection change.** Preflight classifies whatever
  backend and image it is given; it does not move runs between backends
  or alter scheduling.
- **Not a persisted model.** Receipts are returned to the caller (and
  printed by the rake task); no new tables store them. Persistence, if
  #5326's harness needs it, is that owner's call.
