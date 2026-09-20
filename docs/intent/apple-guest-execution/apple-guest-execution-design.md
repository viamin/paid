---
parent: PAID
prefix: APPLE-VERIFY
---

# Low-Level Design: Apple Guest Execution

## Purpose

Apple verification runs untrusted project build phases, tests, UI helpers, and
application binaries inside a disposable macOS guest. The control plane records
the immutable guest image selected for an attempt, while the guest accepts only
a small, versioned verification protocol. Neither surface is a general-purpose
macOS runner or agent environment.

## Immutable worker images

`AppleVerificationImage` is the operator-visible registry of published guest
images. An image records its immutable digest, macOS and Xcode versions/builds,
installed SDKs and Simulator runtimes, executor version, resource envelope,
network capability, GUI-account posture, and smoke-test result. These facts are
immutable after publication; correcting or rebuilding an image creates another
record with another digest.

An image begins as `candidate`. `promote!` permits `candidate -> active` only
after a passing smoke test. Operators can deprecate an active image only with a
future retirement time that establishes a migration window, retire it after
that window, or revoke it immediately for a
security incident. Active images are schedulable; all other states remain
visible for audit but are unavailable to new attempts. Lifecycle changes are
tracked by Logidze.

The guest posture records a dedicated non-admin GUI account with no Apple ID,
personal data, host credentials, or persistent secret-bearing keychain. The
registry rejects a claimed ready image that does not declare each condition.

## Guest protocol

`AppleVerification::GuestProtocol` validates a JSON-compatible job manifest
before guest execution. The manifest has protocol version `1` and a sequence
of typed operation objects. The vocabulary covers source materialization,
Swift package resolution, Xcode inspection, build, test, Simulator boot,
application launch, declarative UI actions, captures, diagnostics, and artifact
export.

An operation has exactly a named type and a typed payload; each operation type
has its own closed set of payload fields. The protocol rejects unexpected
manifest, operation, and payload fields, as well as unknown versions, unknown
operation names, non-object payloads, and shell-like fields (`command`,
`shell`, `script`, and `executable`). This deliberately prevents a repository
configuration from turning the trusted executor into a remote shell.
The executor may invoke Xcode or Simulator tools for an allowed operation; any
repository build phase, test target, XCUITest, script, or helper launched by
those tools is untrusted project code and runs only in the VM.

Capture operations declare their platform and capture target. iOS/iPadOS use a
Simulator screen; macOS uses an application window. Structured results identify
launch, readiness, action, selection, or export failure instead of collapsing
them into a generic capture error.

## Control-plane dispatch

`AppleVerification::ExecuteGuestJob` is the gated control-plane entry point for
a submitted guest manifest. It refuses work unless the project has the
`apple_verification_workers` rollout enabled, selects the active image matching
the immutable digest chosen by the control plane for the project's account, and
validates the manifest before sending it through the provider-owned guest
connection to the closed guest executor vocabulary. The control plane does not
hold operation adapters or execute project work. An account with no active
image matching that digest cannot dispatch work. This keeps worker-profile
selection deterministic when an account has multiple active images.

The image provenance records the HTTPS guest-executor endpoint as an immutable
build fact. `GuestConnection` posts the selected digest and validated manifest
to that endpoint with the deployment-owned bearer token; it rejects missing
credentials, authentication failures, non-success responses, and malformed
executor results. The token is never persisted in image metadata.

## Relationship to Apple Verification Workers

`docs/intent/apple-verification-workers/` models the account-facing worker
contract: profiles, workflow revisions, attempts, and waivers. This segment
models the infrastructure those attempts run on: the immutable guest image
catalog and the deterministic protocol the control plane speaks to a guest.
`AppleWorkerProfile#image_digest` names an `AppleVerificationImage#digest`
by value; the two records are not foreign-keyed together because a worker
profile is provider-neutral policy while an image is an operator-published,
provider-specific build artifact.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Keep Apple images separate from OCI `AgentImage` records | A VM image is identified and provisioned differently from a container image, and has Apple-specific toolchain and GUI posture facts. | Add nullable Apple fields to `AgentImage`, which would blur Docker scheduling with VM lifecycle. |
| Validate a closed operation vocabulary before execution | The guest must offer deterministic verification, not shell access. | Accept command strings and attempt to filter them, which cannot preserve the trust boundary. |
