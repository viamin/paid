# EARS Specs: Stateless Hosts — Shared Artifact Storage

> Testable claims for the shared artifact storage abstraction that keeps hosts
> disposable. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r ARTIFACT-STORAGE-001`).

- [x] **ARTIFACT-STORAGE-001** — The system SHALL provide a shared
  `ArtifactStorage` module that constructs a single S3-compatible client
  (region, credentials, endpoint, bucket) from the `SCREENSHOTS_S3_*`
  environment variables / Rails credentials and exposes generic `upload`,
  `signed_url`, `delete`, and `delete_prefix` operations for arbitrary key
  prefixes, so any durable binary artifact type reuses one storage abstraction.
  *Code:* `app/services/artifact_storage.rb`.
  *Test:* `spec/services/artifact_storage_spec.rb`.

- [x] **ARTIFACT-STORAGE-002** — When object storage credentials are absent,
  `ArtifactStorage.configured?` SHALL return false (and `upload`/`signed_url`/
  `delete` remain available but callers SHALL degrade gracefully), and when
  credentials are present it SHALL return true using the same resolution as the
  historical screenshot configuration.
  *Code:* `app/services/artifact_storage.rb`.
  *Test:* `spec/services/artifact_storage_spec.rb`.

- [x] **ARTIFACT-STORAGE-003** — `Screenshots::Storage` SHALL compose an
  `ArtifactStorage` and reach for the shared S3 client through it instead of
  constructing its own client, while preserving its screenshot-specific key
  layout, listing behavior, and content-type-aware upload helpers.
  *Code:* `app/services/screenshots/storage.rb`.
  *Test:* `spec/services/screenshots/storage_spec.rb`,
  `spec/services/artifact_storage_durability_spec.rb`.

- [x] **ARTIFACT-STORAGE-004** — The `SCREENSHOTS_S3_*` configuration consumed
  by `ArtifactStorage` SHALL default to the same bucket, region, and credential
  resolution that `Screenshots::Storage` used before extraction, so existing
  deployments require no configuration changes.
  *Code:* `app/services/artifact_storage.rb`.
  *Test:* `spec/services/artifact_storage_spec.rb`.

- [x] **ARTIFACT-STORAGE-005** — The system SHALL keep Rails and Temporal worker
  hosts disposable: every durable artifact SHALL reside either in PostgreSQL
  (e.g. `AgentRunLog`, `TokenUsage`) or in external object storage reached
  through `ArtifactStorage`, and never on the host filesystem; a test SHALL
  verify durable records are DB-backed and durable binaries flow through the
  shared object-storage client.
  *Code:* `app/services/artifact_storage.rb`, `docs/ARTIFACT_STORAGE.md`.
  *Test:* `spec/services/artifact_storage_durability_spec.rb`.
