---
parent: PAID
prefix: APPLE-TRANSFER
---

# Low-Level Design: Apple Verification Source, Results, and Artifact Transfer

## Purpose

Apple verification work crosses three control-plane boundaries — committed
source checkout, uncommitted workspace bundling, and structured result/artifact
ingestion — every one of which must keep credentials and host artifacts out of
the macOS guest. This segment extends the existing
`AppleVerificationWorkers` transfer lanes rather than introducing a new
transport: committed runs bind to an exact commit and receive only a
short-lived read-only GitHub App installation credential through the
`credentials` lane, uncommitted runs ship a content-addressed bundle that
excludes secrets, caches, derived data, and forbidden artifacts, and the guest
verifies the bundle digest before execution.

## Source lane

`AppleVerification::SourceLane::Build` (RDR-068 § Source and Credential
Transfer) turns an attempt's source identity into the four lane references the
`InputManifest` consumes. The lane is built from an
`AppleVerificationAttempt` whose `commit_sha` (committed) or
`source_digest` (uncommitted) is fixed at attempt creation; a second call with a
different identity is rejected because the attempt's `execution_binding` is
immutable (`AppleVerificationAttempt#execution_binding_is_immutable`).

For committed runs, the git lane carries the exact commit identity as a
`repository_checkout` reference and the credentials lane carries a
`github_app_installation` reference. The token is fetched from
`Github::AppInstallation.token_for` with a TTL bounded to the
GitHub-issued window — never a long-lived PAT. The credentials lane entry
records only the installation id, repository full name, and token TTL; the
token value is delivered out-of-band to the guest executor through the
authenticated `GuestConnection` channel and never persisted in the attempt,
the manifest, or any artifact.

For uncommitted runs, the object-storage lane carries a
`workspace_bundle` reference whose locator names the bundle digest (SHA-256),
size, and content-type, and whose metadata names the manifest of excluded
paths, secret-scan summary, and the attempts from which the bundle was built.
The lane never references a host path, a bind mount, or a cross-project
shared cache: bundles are produced by `AppleVerification::SourceLane::BundleBuilder`
inside the originating paid-agent container, uploaded through `ArtifactStorage`,
and addressed only by digest.

## Bundle construction

`AppleVerification::SourceLane::BundleBuilder` builds the bundle on disk,
produces the safe manifest, computes the digest, and writes the metadata blob.
The builder enforces the exclusion policy from RDR-068:

- credentials and secret-shaped files (`.env`, `*.pem`, keychains, `id_rsa*`,
  `*.p12`, `*.key`, `~/.netrc`, `~/.aws/credentials`, `secrets/`, the
  `paid.config.json`, `runner_handle.json`, and any file matching the
  `SecretSafeMetadata::SECRET_VALUE_PATTERNS`);
- package and dependency caches (`Pods/`, `Carthage/Build/`, `DerivedData/`,
  `*.xcworkspace/xcuserdata`, `.build/`, `.swiftpm/`, `node_modules/`,
  `vendor/bundle`, `.bundle/`, `target/`, `dist/`, `out/`);
- build outputs (`build/`, `*.xcarchive`, `*.xcappdata`,
  `*.dSYM`, `*.ipa`, `*.app`, `DerivedSources/`);
- paid-agent host artifacts and forbidden binary types.

Excluded paths are recorded in the manifest's `excluded_paths` array and the
bundle's tar stream omits them. The builder then walks the remaining tree,
streams a SHA-256 digester, and produces the bundle alongside a
`manifest.json` listing every included file's digest and the exclusion
summary. The bundle digest is `sha256:` + the digester's final hex output.
Bundles larger than the configured cap (default 2 GiB) are rejected with
`BundleTooLargeError` before upload.

The builder rejects attempts where `AgentRuns::Research::SecretGuard` would
flag the workspace, where the bundle already exists with a different digest,
or where the agent run has a write-host mount bound into its container (the
manifest's `mounts`/workspace section would expose one). Bundles are
content-addressed: a duplicate digest reuses the existing object-storage key
instead of re-uploading.

## Credential lane

`AppleVerification::SourceLane::CredentialLane` composes the credentials lane
from the project's active GitHub App installation. It calls
`Github::AppInstallation.token_for` and produces a `github_app_installation`
reference whose locator carries `installation_id`, `repository_id`, and
`ttl_seconds`. The credentials lane rejects an installation that is suspended,
revoked, or attached to an account other than the project's, and rejects
attempts whose `commit_sha` is missing or non-SHA-1.

The token value is never serialized into the manifest — it is delivered to
the guest through the authenticated `GuestConnection` channel when the
executor validates the job. After the attempt finishes, the credential is
revoked by deleting the cached entry in `Github::AppInstallation`; the entry's
deletion is recorded as an `ExecutionAuditEvent`
(`event_name: "apple_credential.revoked"`) without the token value.

## Result manifest

`AppleVerification::ResultManifest::Build` produces the `OutputManifest` after
an attempt completes. It composes:

- `attempt`: id, source_digest, workflow_revision, lifecycle_gate,
  profile_digest, and the committed commit_sha when present;
- `result`: terminal status, queued/provisioning/running/total timings, retry
  lineage (attempt ids), failure_classification, required_checks and
  advisory_checks outcomes, screenshot metadata, network_policy mode, and
  references to execution audit events and external-resource ledger entries;
- `artifacts`: `.xcresult`, build_logs, screenshots, diagnostics, and other
  references (each one a typed object-storage reference that respects the
  per-account namespace).

The manifest's lane entries never carry secret-shaped values, host paths, or
provider lifecycle fields (`AppleVerificationWorkers::FORBIDDEN_KEYS`). The
manifest is validated through `AppleVerificationWorkers::OutputManifest` so a
regression that lets a credential or host path slip in fails closed before it
is recorded.

## Artifact ingestion

`AppleVerification::ArtifactIngestion::Ingest` accepts an attempt and a list
of artifact descriptors from the guest executor, uploads each one through the
shared `ArtifactStorage` (`xcodebuild`, `.xcresult`, screenshots, log bundles,
diagnostics), and returns the validated object-storage references for the
output manifest. Each artifact's key is namespaced under
`apple-verification/{account_id}/{project_id}/{attempt_id}/{kind}/{name}` so
the key cannot collide with screenshot, run, or knowledge namespaces.

The ingester enforces the RDR's retention policy: durable records (manifest
metadata, attempt metadata, audit references) are kept forever, while binary
artifacts follow the configured retention (default 30 days, configurable per
account). Expired artifacts are deleted by `AppleVerification::Artifacts::RetentionSweep`,
which deletes binaries by key prefix while preserving durable metadata rows.

## Revocation and deletion rules

`AppleVerification::Revocation::Enforce` runs the RDR's revocation rules:

- A successful attempt's VM is destroyed immediately; the attempt records the
  `verification_vm_destroyed` audit event and the credentials lane entry is
  revoked.
- A failed attempt retains its VM for the configured retention window
  (default 1 hour). The retention window is recorded on the attempt as
  `retained_until`. The VM is destroyed on the earlier of explicit destroy,
  retention expiry, or worker profile revocation; an expired VM triggers the
  same audit event and credential revocation.
- A workspace bundle is retained for the configured window after the attempt
  completes (default 7 days, configurable per account). The retention window
  is recorded on the attempt as `bundle_retained_until`. An expired bundle
  is deleted by `AppleVerification::Bundles::RetentionSweep` which lists
  prefixes under `apple-verification/{account_id}/{project_id}/{attempt_id}/`
  and removes expired keys, preserving the bundle metadata row (digest, safe
  manifest summary, lineage).
- The attempt record, manifest, audit events, ledger entries, and
  durable metadata survive binary expiry: retention deletion only removes
  the binary artifact keys, never the metadata rows that reference them.

## Rollout

The default-off `apple_verification_workers` feature flag gates every entry
point. Project mode and operator approval remain separate gates supplied by
the Apple worker control plane; this segment does not modify scheduling.

## Decisions and alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Reuse `AppleVerificationWorkers::InputManifest` and `OutputManifest` lanes | Existing provider-neutral contract already rejects host paths and secret-shaped values. | New lane names, which would require a parallel secret/host-path scan. |
| Address bundles by content digest in object storage | Cross-run and cross-project reuse, deduped uploads, and digest verification in the guest. | A writable cross-project cache, which would let one project influence another's workspace. |
| Persist bundle metadata rows separately from binary keys | Metadata must survive binary expiry for audit and lineage. | A single record that disappears with the binary. |
| Revoke credentials after attempt completion regardless of outcome | A failed VM that retains authority is a security regression. | Keep credentials for the retention window, which would let a retained VM act beyond its scope. |

*HLD:* `docs/high-level-design.md` → isolation by default and durable data.
*RDR:* [RDR-068](../rdrs/RDR-068-apple-platform-verification-workers.md).
