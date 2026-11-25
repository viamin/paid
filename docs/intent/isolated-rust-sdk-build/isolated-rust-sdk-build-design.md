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
> `Dynamic loader not found: /lib64/ld-linux-x86-64.so.2`. That loader path
> establishes that the failed binary was x86-64; it does not, by itself,
> establish the runner process architecture. The historical container
> and its mutable-tag image are gone, so the original provisioning failure
> cannot be reproduced; what Paid can own is the supported path that makes
> that failure class impossible to hit silently.

## Purpose

Give the SDK prototype owner (#5326) an independently runnable,
reproducible preflight prerequisite for Rust/SDK builds in Paid's supported
execution environment — Docker-backed containers with digest-pinned,
architecture-matched toolchain images — without touching host or
control-plane SDK pins, operating workers, or the agent image. The build and
native-artifact load capability remains the prototype's job-scoped concern;
this segment does not represent metadata classification as build evidence.

## Scope boundaries

- **Environment capability only.** The Core/Ruby prototype, the
  finite-attempt harness, and any client/server workflow tests belong to
  #5326. This segment provides the environment: pins, preflight, and the
  classification of loader/architecture failures.
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
kernel refuses to exec it when that loader is absent. An x86-64 binary
records `/lib64/ld-linux-x86-64.so.2`; an aarch64 binary records
`/lib/ld-linux-aarch64.so.1`. The error text names the *binary's*
architecture, not the runner's; the runner profile must be collected
separately before compatibility can be determined. The recorded x86-64
loader signature is therefore diagnostic evidence of the downloaded
toolchain artifact, while the original runner architecture remains
unverified by that line alone.

`SdkBuildEnvironments::ArchitectureCompatibility` owns this mapping:

- normalize architecture aliases (`x86_64`/`x64` → `amd64`,
  `aarch64`/`arm64` → `arm64`, `armv7l`/`armhf` → `arm`);
- derive the architecture an ELF interpreter path implies, including
  Debian multiarch resolved paths
  (`/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1`);
- classify an observed toolchain against the runner architecture as
  `:compatible`, `:architecture_mismatch`, or `:unknown`, with the
  mismatch naming both sides;
- recognize the reported failure signature from container output; when a
  recognized loader and runner profile differ, classify it as a
  foreign-architecture binary execution attributed to the loader path's
  architecture, and when the runner profile is unavailable, retain an
  unknown-process classification rather than asserting compatibility.

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

Before any build container is provisioned, the capability pulls the selected
digest-pinned image on the selected backend, then captures a
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

## Independent runnability and consumer invocation

`rake sdk_build_environment:preflight` runs the same classification
against a real backend and prints the receipt as JSON. It performs
metadata probes only, provisions nothing, and requires no run, project,
or worker state — the environment prerequisite stays independently
runnable, per the issue's "no explicit dependency on #5326" constraint.

The existing SDK prototype owner invokes the usable baseline through the
confirmation-gated `build_pinned_rust_sdk_core` agent tool, supplying its
authorized project and acting agent-run identifiers. The tool resolves the
run's selected backend through `Containers.backend_for`; it does not grant
the agent a Docker socket, host path, or a new native-attempt allowance.
`SdkBuildEnvironments::PinnedCoreBuild` first requires a compatible
preflight, builds a temporary image from the immutable SDK/Core source pins,
then starts a separate capability-dropped, network-disabled container for
`cargo check --locked --offline --package temporalio-sdk-core`. It returns
the command, bounded output, exit status, preflight, and cleanup receipt,
and removes both the container and temporary image in `ensure`. A single
monotonic deadline covers image build and every check phase; no new build or
check operation starts after it expires. Cleanup follows a separate explicit,
bounded best-effort transport policy so owned resources are still removed when
the build deadline is exhausted. The image build receives the same memory, CPU,
and process envelope as the check and uses force-removal so an interrupted build
cannot leave its job tag behind.
The Dockerfile installs the exact recorded libclang package versions, verifies
the pinned `libclang.so.1` digest, initializes the Ruby SDK's actual
`temporalio/ext/sdk-core` gitlink, and runs Cargo from `/sdk/temporalio`, whose
lockfile is the recipe's recorded source identity.

## Decisions & Alternatives

| Decision | Rationale | Alternatives rejected |
| --- | --- | --- |
| Classify the failure class, not reproduce it | The original container, its mutable-tag image, and the exact downloaded artifact are gone; manufacturing a reproduction would be fabrication. The classifier turns the recorded signature into actionable, testable diagnosis. | Re-running rustup install blindly and hoping to hit the same error; attributing the historical image content without evidence. |
| Frozen recipe data, not `bin/update` pins | The SDK build toolchain is job-scoped input for #5326's harness, not a Paid environment every agent image carries. Wiring it into the pin registry would change control-plane pin surface, which the issue forbids. | Adding Rust to the agent base image (host pin change, unrequested rollout); extending combo language layers (same problem at a different layer). |
| Digest-pinned official toolchain images | Root verified the official ARM64 images by immutable digest; mutable tags would reintroduce exactly the unmeasured-identity gap that made the historical failure undiagnosable. | Trusting `rust:latest`-style tags; vendoring a toolchain into the repo. |
| Injectable facts probe | Keeps classification hermetic and testable without a daemon, following the `AppleVerification::Setup::Shell` precedent. | Requiring a live daemon in unit tests; shelling out from the model layer. |
| Record Ruby build profile with the pins | The static/shared ABI gap silently invalidates cross-profile load claims (root's ABI control receipts). Recording it makes the limitation structural rather than tribal knowledge. | Treating "Ruby 3.4.13" as sufficient identity. |
| Dedicated agent tool for the Core baseline | Gives #5326 one job-scoped invocation through its existing authorization and selected backend, while keeping Docker authority inside Paid. | Giving an agent a Docker socket; a generic user-command build service. |

## What this is not

- **Not an SDK test harness.** The fixed Core check establishes only the
  version-bound build baseline; client/server workflows and native artifact
  load evidence remain #5326's finite-attempt harness concern.
- **Not a runner selection change.** Preflight classifies whatever
  backend and image it is given; it does not move runs between backends
  or alter scheduling.
- **Not a persisted model.** Receipts are returned to the caller (and
  printed by the rake task); no new tables store them. Persistence, if
  #5326's harness needs it, is that owner's call.
