---
parent: PAID
prefix: ARTIFACT-STORAGE
---

# Low-Level Design: Stateless Hosts — Shared Artifact Storage

> Companion to the high-level design (`docs/high-level-design.md`) and
> `docs/ARTIFACT_STORAGE.md` (the classified artifact inventory). This segment
> covers the shared object-storage abstraction that keeps Rails and Temporal
> worker hosts disposable.

## Purpose

Paid's core production invariant is that destroying or replacing a Rails or
Temporal worker host must not destroy important state. Durable application
state already lives in PostgreSQL (agent run logs, token usage/cost, billing,
configuration). Durable *binary* artifacts — screenshots, Playwright traces,
trace-viewer assets — already reached S3-compatible object storage, but through
a screenshot-specific client (`Screenshots::Storage`) with no shared abstraction.
Any future durable artifact (generated reports, build outputs, diff artifacts)
would have had to construct its own S3 client, risking configuration drift and
breaking the invariant.

This segment extracts a single shared storage interface so every durable binary
artifact type reuses one client-construction path, and documents the inventory
so the storage contract is explicit.

## Shipped Behavior

`ArtifactStorage` (`app/services/artifact_storage.rb`) is a plain Ruby class
(autoloaded under `app/services/`) that owns:

- **Client construction** — `Aws::S3::Client` built from region, credentials,
  endpoint, and bucket resolved from the `SCREENSHOTS_S3_*` environment
  variables / Rails credentials, with the historical defaults
  (`paid-screenshots`, `us-east-1`). Endpoint presence toggles path-style
  addressing for S3-compatible providers (MinIO, R2).
- **Generic operations** for arbitrary key prefixes — `upload` (returns a
  presigned GET URL; infers content type from the filename), `signed_url`,
  `delete`, and `delete_prefix` (sweeps a prefix, returns the deleted count).
- **Configuration checks** — `configured?` (instance and class) so callers
  degrade gracefully when object storage is absent.

`Screenshots::Storage` was refactored to **compose an `ArtifactStorage`** for
S3 client construction. It keeps its screenshot-specific responsibilities
(key layout, before/after listing, retention cleanup, content-type-aware
upload helpers) and reaches for the shared client, bucket, and signed URL
through `@artifact_storage` internally. Callers that need direct S3 access
(`Previews::TraceViewer`) now depend on `ArtifactStorage` directly rather than
via `Screenshots::Storage`. The historical re-exports (`DEFAULT_BUCKET`,
`DEFAULT_REGION`, `MAX_URL_TTL`, `DEFAULT_URL_TTL`) and delegations
(`client`/`bucket`/`region`/`signed_url`/`configured?`) were cut so external
callers must reference `ArtifactStorage` for the shared storage surface.

## Scope decisions

- **Default to the existing config.** `ArtifactStorage` resolves the same
  `SCREENSHOTS_S3_*` variables and `screenshots.s3.*` credentials as before, so
  existing deployments need no changes and screenshots/traces/viewer assets
  continue to share one bucket.
- **Generic, prefix-based API.** Operations take a full key (with any prefix),
  so a new artifact type uses its own key namespace (`reports/...`,
  `builds/...`) without a new class. A dedicated bucket is still possible via
  the `bucket:` constructor override.
- **Content type from the filename.** `upload` infers the MIME type via
  `Marcel::MimeType.for(name:)` (extension-authoritative) rather than magic-byte
  sniffing, so the type the caller named the file is honored deterministically.
- **Workspace storage stays out of scope.** Git worktree/workspace coupling is
  execution-scoped and tracked by the runner extraction (#3342). This segment
  provides the abstraction for *other* durable artifacts and documents the
  invariant; it does not redesign workspace storage.

## What this is not

- **Not a provider migration.** S3 compatibility already existed; this is a
  client-construction extraction, not a change of storage provider.
- **Not a CDN / public-serving layer.** Presigned GET URLs remain the serving
  model for user-visible artifacts.
- **Not a durability guarantee for the DB.** PostgreSQL durability is the
  database's responsibility; this segment only ensures binary artifacts are
  routed off the host filesystem.

## References

- `docs/ARTIFACT_STORAGE.md` — classified artifact inventory and storage tiers
- `docs/PRODUCTION_CONFIG.md` — production required/warned variable list
- `app/services/artifact_storage.rb`
- `app/services/screenshots/storage.rb`
- `app/services/previews/trace_viewer.rb`
- `spec/services/artifact_storage_spec.rb`
- `spec/services/artifact_storage_durability_spec.rb`
- `spec/services/screenshots/storage_spec.rb`
