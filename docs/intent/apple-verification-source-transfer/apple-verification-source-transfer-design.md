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
summary. Tar entries preserve each included file's permission bits so
executable build-phase scripts survive extraction in the guest. The bundle
digest is `sha256:` + the digester's final hex output.

The builder rejects the bundle when:

- any included file matches a secret-shaped pattern from
  {SecretSafeMetadata::SECRET_VALUE_PATTERNS} after the exclusion pass;
- the resulting bundle exceeds `max_bytes` (default 2 GiB)
  (`BundleTooLargeError`);
- the workspace contains a symlink whose target, resolved through the entire
  symlink chain via `File.realpath`, sits outside the workspace root
  (`WorkspaceInvalidError`).

[ ] **Gap:** A host-mount guard at the source-lane level
(`AppleVerification::SourceLane::Build#ensure_no_host_mounts!`) rejects
attempts whose originating paid-agent container has a write host mount bound
into its workspace; the executor that drives the source lane is the only
party that can resolve the container's bind/mount table, so the guard takes
a required `host_mount_check:` callable and refuses to run without it. The
bundle builder itself does not inspect container mounts.

## Credential lane

`AppleVerification::SourceLane::CredentialLane` composes the credentials lane
from the project's active GitHub App installation. It calls
`Github::AppInstallation.token_for` and produces a `github_app_installation`
reference whose locator carries `installation_id`, `repository_id`, and
`ttl_seconds`. The credentials lane rejects an installation that is suspended,
revoked, or attached to an account other than the project's, and rejects
attempts whose `commit_sha` is missing.

[ ] **Gap:** The credentials lane currently rejects an attempt whose
`commit_sha` is blank but does not validate the SHA-1 (40-hex) shape. A
follow-up should tighten `CredentialLane#committed?` (or the attempt model)
to reject non-SHA-1 values, matching the documented contract.

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

Descriptors are untrusted guest input and carry their payload inline
(`bytes`). Any descriptor naming a host path — `host_path`, `host_mount`, or
`file_path` — is rejected before upload, so artifact bytes are never read
from the Rails host filesystem. The locator's `sha256` digest is computed
server-side from the uploaded bytes, and a guest-reported digest that
disagrees with those bytes is rejected (`DigestMismatchError`).

The ingester enforces the RDR's retention policy: durable records (manifest
metadata, attempt metadata, audit references) are kept forever, while binary
artifacts follow the configured retention (default 30 days, configurable per
account, see `AppleVerification::ArtifactIngestion::Storage::DEFAULT_BINARY_RETENTION_DAYS`).

[ ] **Gap:** A dedicated artifact-binary retention sweep is not part of this
segment; this PR only ships the workspace-bundle retention sweep
(`AppleVerification::Bundles::RetentionSweep`, see Revocation and deletion
rules below). A follow-up should add an `AppleVerification::Artifacts::RetentionSweep`
that deletes only the per-kind artifact keys (`.xcresult`, build logs,
screenshots, diagnostics) at their configured expiry while preserving the
durable metadata rows, mirroring the bundle-sweep shape.

[ ] **Gap:** The `DEFAULT_BINARY_RETENTION_DAYS` constant is defined but not
yet wired into a sweep — artifact binaries are retained until that sweep
lands. This is a follow-up rather than a bug: artifact retention must not
shorten below the bundle retention window.

## Revocation and deletion rules

`AppleVerification::Revocation::Enforce` runs the RDR's revocation rules:

- A successful attempt's VM is destroyed immediately; the attempt records the
  `verification_vm_destroyed` audit event and the credentials lane entry is
  revoked.
- A failed attempt retains its VM for the configured retention window
  (default 1 hour). The retention window is recorded on the attempt as
  `retained_until`. The VM is destroyed on the earlier of explicit destroy,
  retention expiry, or worker profile revocation; an expired VM triggers the
  same audit event and credential revocation. The sweep drives the real
  destroy through `AppleVerification::Lifecycle#destroy` (which calls the
  macOS host service's `destroy` operation, marks the
  `ExecutionResourceLedgerEntry` deleted, and is idempotent for attempts
  with no live ledger entry) before recording the
  `apple_verification_vm.destroyed` audit event, so the audit event
  reflects an actual destroy rather than a no-op.
- A workspace bundle is retained for the configured window after the attempt
  completes (default 7 days, configurable per account). The retention window
  is recorded on the attempt as `bundle_retained_until`; uncommitted
  attempts — successful or failed — persist the deadline from
  {AppleVerification::Revocation::Enforce}, while committed attempts leave
  it `NULL` because they ship no bundle. An expired bundle is deleted by
  `AppleVerification::Bundles::RetentionSweep`, which deletes only the
  bundle key
  (`AppleVerification::ArtifactIngestion::Storage.bundle_key` → `source.tar`)
  so the sibling artifact keys (`.xcresult`, build logs, screenshots,
  diagnostics) uploaded by
  {AppleVerification::ArtifactIngestion::Ingest} are preserved for their own
  retention window. The sweep then clears `bundle_retained_until` on the
  attempt so the durable manifest, audit events, and ledger entries remain
  attributable while the binary artifact is gone.
- The credentials lane entry is revoked by
  `Github::AppInstallation.revoke_token`, which calls
  `DELETE /installation/token` authenticated with the cached token itself
  before clearing the local cache, so a retained failed VM cannot replay an
  old installation token against the GitHub API during the retention window.
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
