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
> `Dynamic loader not found: /lib64/ld-linux-x86-64.so.2` — an x86-64
> dynamic loader requested on an aarch64 host. The historical container
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
`/lib/ld-linux-aarch64.so.1`. On an aarch64 host the x86-64 path never
exists, so the error text names the *binary's* architecture, not the
host's — which is why the agent's retry with an "aarch64 default host"
changed nothing: the host was already aarch64; the downloaded toolchain
artifact was not.

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
cargo/rustc paths, and each toolchain binary's ELF architecture and
interpreter path. The receipt carries a check-based verdict —
`compatible`, or a named failure (`image_architecture_mismatch`,
`toolchain_absent`, `loader_architecture_mismatch`, `unverifiable`) with
a remediation hint — so an unsupported pairing fails loudly before
Cargo ever runs, instead of surfacing as a loader error inside a build
log.

The facts are collected through an injectable probe object so the
service runs under tests without a Docker daemon; the production probe
uses the backend API (`system_info`, image inspect, a disposable
metadata container with bounded resources and no network). Receipts are
metadata-only: commands and outcomes, never credential material.

## Independent runnability

`rake sdk_build_environment:preflight` runs the same classification
against a real backend and prints the receipt as JSON. It performs
metadata probes only, provisions nothing, and requires no run, project,
or worker state — the environment prerequisite stays independently
runnable, per the issue's "no explicit dependency on #5326" constraint.

## Decisions & Alternatives

| Decision | Rationale | Alternatives rejected |
| --- | --- | --- |
| Classify the failure class, not reproduce it | The original container, its mutable-tag image, and the exact downloaded artifact are gone; manufacturing a reproduction would be fabrication. The classifier turns the recorded signature into actionable, testable diagnosis. | Re-running rustup install blindly and hoping to hit the same error; attributing the historical image content without evidence. |
| Frozen recipe data, not `bin/update` pins | The SDK build toolchain is job-scoped input for #5326's harness, not a Paid environment every agent image carries. Wiring it into the pin registry would change control-plane pin surface, which the issue forbids. | Adding Rust to the agent base image (host pin change, unrequested rollout); extending combo language layers (same problem at a different layer). |
| Digest-pinned official toolchain images | Root verified the official ARM64 images by immutable digest; mutable tags would reintroduce exactly the unmeasured-identity gap that made the historical failure undiagnosable. | Trusting `rust:latest`-style tags; vendoring a toolchain into the repo. |
| Injectable facts probe | Keeps classification hermetic and testable without a daemon, following the `AppleVerification::Setup::Shell` precedent. | Requiring a live daemon in unit tests; shelling out from the model layer. |
| Record Ruby build profile with the pins | The static/shared ABI gap silently invalidates cross-profile load claims (root's ABI control receipts). Recording it makes the limitation structural rather than tribal knowledge. | Treating "Ruby 3.4.13" as sufficient identity. |

## What this is not

- **Not an SDK test harness.** No SDK source is cloned, built, or tested
  by this segment's code; the recipe and preflight are consumed by
  #5326's finite-attempt harness.
- **Not a runner selection change.** Preflight classifies whatever
  backend and image it is given; it does not move runs between backends
  or alter scheduling.
- **Not a persisted model.** Receipts are returned to the caller (and
  printed by the rake task); no new tables store them. Persistence, if
  #5326's harness needs it, is that owner's call.
