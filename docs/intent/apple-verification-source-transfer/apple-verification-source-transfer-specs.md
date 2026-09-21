# EARS Specs: Apple Verification Source, Results, and Artifact Transfer

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code.

- [x] **APPLE-TRANSFER-001** — When a verification attempt runs against
  committed source, the input manifest's git lane SHALL carry the exact
  attempt's commit identity and the credentials lane SHALL carry only a
  short-lived read-only GitHub App installation reference scoped to the
  attempt's repository; the credential lane entry SHALL reject an installation
  that is suspended, revoked, or attached to a different account, and the
  manifest SHALL never carry the resolved installation token value.
  *Tests:* `spec/services/apple_verification/source_lane/credential_lane_spec.rb`
  *Code:* `AppleVerification::SourceLane::CredentialLane`,
  `AppleVerification::SourceLane::Build`

- [x] **APPLE-TRANSFER-002** — When a verification attempt runs against
  uncommitted source, the input manifest's object-storage lane SHALL carry a
  content-addressed workspace bundle reference (digest, size, manifest) and
  the builder SHALL exclude credentials, package and dependency caches,
  build outputs, paid-agent host artifacts, and any file matching
  `SecretSafeMetadata::SECRET_VALUE_PATTERNS`; excluded paths SHALL be
  recorded in the bundle manifest, the bundle SHALL be rejected if any
  included file matches a secret-shaped pattern after the exclusion pass,
  and each included file's permission bits SHALL be preserved in the
  bundle's tar entries so executable scripts survive extraction.
  *Tests:* `spec/services/apple_verification/source_lane/bundle_builder_spec.rb`
  *Code:* `AppleVerification::SourceLane::BundleBuilder`

- [x] **APPLE-TRANSFER-003** — The source lane SHALL reject manifests that
  reference a host path, a bind mount, or a writable cross-project cache, and
  the bundle builder SHALL refuse to build a bundle when the originating
  paid-agent container has a write-host mount bound into its workspace.
  *Tests:* `spec/services/apple_verification/source_lane/bundle_builder_spec.rb`,
  `spec/services/apple_verification/source_lane/build_spec.rb`
  *Code:* `AppleVerification::SourceLane::Build`,
  `AppleVerification::SourceLane::BundleBuilder`

- [x] **APPLE-TRANSFER-004** — The output manifest produced for an attempt
  SHALL include the attempt identity, source/lineage, workflow revision and
  lifecycle gate, profile digest, terminal status, queued/provisioning/running/
  total timings, retry lineage, failure classification, required and advisory
  check outcomes, screenshot metadata, network policy mode, and references to
  execution audit events and external-resource ledger entries; the manifest
  SHALL be validated against `AppleVerificationWorkers::OutputManifest` and
  SHALL reject host paths, provider lifecycle fields, and secret-shaped values.
  *Tests:* `spec/services/apple_verification/result_manifest/build_spec.rb`
  *Code:* `AppleVerification::ResultManifest::Build`

- [x] **APPLE-TRANSFER-005** — `.xcresult`, build logs, screenshots, and
  diagnostics produced by an attempt SHALL be uploaded through the shared
  `ArtifactStorage` under a per-account/per-project/per-attempt namespace and
  SHALL be addressed in the output manifest as object-storage references
  whose locator digest is computed server-side from the uploaded bytes;
  artifact descriptors are untrusted guest input, SHALL carry their payload
  inline, any descriptor naming a host file path (`host_path`, `host_mount`,
  or `file_path`) SHALL be rejected, and a guest-reported digest that
  disagrees with the uploaded bytes SHALL be rejected; the durable manifest
  metadata, attempt record, audit events, and ledger entries SHALL survive
  the binary retention window.
  *Tests:* `spec/services/apple_verification/artifact_ingestion/ingest_spec.rb`
  *Code:* `AppleVerification::ArtifactIngestion::Ingest`

- [x] **APPLE-TRANSFER-006** — A successful attempt SHALL destroy its VM
  immediately and revoke its credential lane entry; a failed attempt SHALL
  retain its VM for the configured retention window (default 1 hour) and the
  retention deadline SHALL be persisted on the attempt; a workspace bundle
  SHALL be retained for the configured window after the attempt completes
  (default 7 days); an expired VM, credential, or bundle SHALL be revoked or
  deleted according to the RDR's rules and the action SHALL be recorded as an
  execution audit event without the credential token value.
  *Tests:* `spec/services/apple_verification/revocation/enforce_spec.rb`,
  `spec/services/apple_verification/bundles/retention_sweep_spec.rb`
  *Code:* `AppleVerification::Revocation::Enforce`,
  `AppleVerification::Bundles::RetentionSweep`
