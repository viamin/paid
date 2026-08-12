# Artifact Storage & Stateless Hosts

> Companion to the high-level design (`docs/high-level-design.md`) and the
> `artifact-storage` intent segment (`docs/intent/artifact-storage/`).
>
> **Production invariant:** destroying or replacing a Rails or Temporal worker
> host must not destroy important Paid state.

This document is the complete, classified inventory of every artifact Paid
writes during operation. Each artifact is routed to the storage tier that
matches its durability requirement so that hosts are disposable — you can
terminate and recreate any Rails/worker instance without losing user-visible
data or breaking in-flight work.

## Storage tiers

| Tier | Backing | Used for |
|------|---------|----------|
| **Durable application state** | PostgreSQL | Records that must survive forever and be queryable: runs, logs, costs, configuration, billing. |
| **Durable binary artifacts** | S3-compatible object storage via `ArtifactStorage` | User-visible binaries that are too large or too opaque for the DB: screenshots, traces, videos, and future artifact types. |
| **Execution-scoped** | Docker volumes / named-volume git clones | Per-run working data that is disposable once the run completes. Lives on the runner, not on a Paid host. |
| **Ephemeral host files** | Host `tmp/` / `log/` | Process-local scratch, tokens, and logs that are safe to lose on host replacement. |

The rule: **if an artifact is durable or user-visible, it goes into PostgreSQL
or through `ArtifactStorage` — never onto the host filesystem.**

## Artifact inventory

| Artifact | Location | Classification | Storage |
|----------|----------|----------------|---------|
| Git bare clones + worktrees | runner workspace (`WorktreeService` → named-volume clones by default) | Execution-scoped (disposable after run) | Runner filesystem (#3342) |
| Agent container workspace volume | Docker named volume per run | Execution-scoped | Docker volume |
| Playwright traces (`.zip`) | container `/tmp` → `Screenshots::Storage.upload_trace` → S3 | **Durable binary artifact** | Object storage (`ArtifactStorage`) |
| Screenshots / GIF / WebM | container → `Screenshots::Storage` (S3) or `Screenshots::BranchStorage` (git branch) | **Durable binary artifact** | Object storage or git branch |
| Trace viewer static bundle | `Previews::TraceViewer` → S3 (`trace-viewer/` prefix) | **Durable binary artifact** | Object storage (`ArtifactStorage`) |
| Preview session containers | Docker containers + rathole tunnels | Execution-scoped | Docker |
| `tmp/paid-preview-rathole.{toml,log,pid}` | host `tmp/` | Ephemeral | Local disk (ok) |
| `tmp/prometheus/metrics_token` | host `tmp/` | Ephemeral (config) | Local disk (ok) |
| Rails logs | `log/production.log` / stdout | Ephemeral | Local disk / stdout (ok) |
| Agent run logs | `AgentRunLog` (PostgreSQL) | **Durable application state** | Database |
| Token usage / cost | `TokenUsage` (PostgreSQL) | **Durable application state** | Database |

## The shared storage abstraction: `ArtifactStorage`

`ArtifactStorage` (`app/services/artifact_storage.rb`) is the single S3-compatible
object-storage interface for durable binary artifacts. It owns:

- **Client construction** — region, credentials, endpoint, and bucket resolution
  from the `SCREENSHOTS_S3_*` environment variables / Rails credentials, with
  safe defaults.
- **Generic operations** — `upload`, `signed_url`, `delete`, and `delete_prefix`
  for arbitrary key prefixes (so a future artifact type does not need its own
  S3 client).
- **Configuration check** — `configured?` (instance + class) so callers degrade
  gracefully when object storage is absent.

`Screenshots::Storage` (screenshots, traces, videos) and `Previews::TraceViewer`
(trace viewer assets) delegate client construction to `ArtifactStorage` rather
than building divergent S3 clients. A new durable artifact type — generated
reports, build outputs, diff artifacts — calls `ArtifactStorage` directly with
its own key prefix (and optionally its own bucket).

```ruby
# A future durable artifact, reusing the shared abstraction:
store = ArtifactStorage.new
url = store.upload(file_path: report.path, key: "reports/#{org}/#{repo}/pr-#{number}/report.pdf")
store.signed_url("reports/#{org}/#{repo}/pr-#{number}/report.pdf")
store.delete_prefix("reports/#{org}/#{repo}/pr-#{number}/")
```

## What is intentionally NOT externalized here

- **Git workspace storage.** `WorktreeService` clones repos into a workspace
  that is mounted into agent containers. On a remote/cloud runner that workspace
  lives inside the runner's own filesystem, not on a Paid host. Decoupling that
  is the runner-extraction effort (#3342); this issue only provides the storage
  abstraction for *other* durable artifacts and documents the invariant.
- **Screenshot provider migration.** S3 compatibility already exists; this is
  not a provider change.
- **Public CDN / artifact-serving layer.** Presigned URLs are the serving model.

## Configuration

Object storage is optional: when unconfigured, screenshot/trace capture is
disabled and callers degrade gracefully. When configured, it defaults to the
single bucket shared by screenshots, traces, and the trace viewer so existing
deployments need no changes.

See `.env.example` (the **Object / Artifact Storage** section) for the complete
variable list and `docs/PRODUCTION_CONFIG.md` for the production contract.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SCREENSHOTS_S3_BUCKET` | Bucket for all durable artifacts | `paid-screenshots` |
| `SCREENSHOTS_S3_REGION` | Bucket region | `us-east-1` |
| `SCREENSHOTS_S3_ACCESS_KEY_ID` | Access key | — |
| `SCREENSHOTS_S3_SECRET_ACCESS_KEY` | Secret key | — |
| `SCREENSHOTS_S3_ENDPOINT` | S3-compatible endpoint URL (MinIO, R2, etc.) | — |
| `SCREENSHOTS_S3_URL_TTL` | Presigned URL lifetime (seconds, ≤ 1 week) | 1 week |

The same variables also resolve from the `screenshots.s3.*` Rails credentials.
