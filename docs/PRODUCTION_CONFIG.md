# Production Configuration

Paid validates its configuration at boot in production so a misconfigured deploy
fails fast with a clear message instead of degrading silently or crashing on the
first request. This document is the complete, explicit production configuration
contract.

The validator lives in `Config::ProductionValidator`
(`app/services/config/production_validator.rb`) and runs from an
`after_initialize` hook in `config/initializers/production_config.rb`, gated on
`Rails.env.production?`.

For deployment sizing and process topology, see [SCALING.md](SCALING.md).

## How validation works

1. **Required settings** — if any are absent or unsafe, the process refuses to
   boot and raises a single `ConfigurationError` that lists **every** offending
   setting. Fix them all and restart; you will not debug one-at-a-time.
2. **Development-unsafe defaults** — settings left at a development default
   (e.g. a `localhost` service address) emit a structured `warn`-level log
   (`message: production_config.unsafe_default`) but do **not** stop boot.
3. **Build commands are skipped** — the Docker image's `assets:precompile` step
   boots Rails in the production environment without runtime secrets; it is
   detected via `Config::ProductionValidator.build_command?` and skipped so the
   image build is not falsely blocked. Runtime processes (web server,
   `bin/jobs`, `bin/temporal_worker`) and deploy-time tasks (`db:prepare`,
   `db:migrate`) carry the deployed secrets and **are** validated.
4. **Development and test are unaffected** — the hook short-circuits before the
   validator is instantiated.

## Required settings (boot fails if missing)

| Setting | How to provide | Notes |
|---|---|---|
| Database credentials | `DATABASE_URL` **or** `PAID_DATABASE_PASSWORD` | `database.yml` production block hardcodes `username: paid` and `database: paid_production`; the password comes from `PAID_DATABASE_PASSWORD`. A full `DATABASE_URL` overrides everything. Either one must be present. Use `DB_HOST` to point at a remote database server. |
| Qdrant API key | `QDRANT_API_KEY` env var **or** `qdrant.api_key` in Rails credentials | Required for the knowledge base. `Paid.qdrant_api_key` returns the value (credentials first, then `QDRANT_API_KEY`); the validator surfaces it together with any other missing setting. |

### Required infrastructure-safety limits

Production also fails fast unless the aggregate capacity and provisioning-rate
limits below are set to positive integers. This keeps admission control
fail-closed in cloud deployments instead of silently using development defaults.

| Category | Required settings | Purpose |
|---|---|---|
| Aggregate requested CPU ceilings | `MAX_GLOBAL_REQUESTED_CPU_QUOTA`, `MAX_BACKEND_REQUESTED_CPU_QUOTA` | Caps the sum of requested CPU across all active executions globally and per selected backend/host. |
| Aggregate requested memory ceilings | `MAX_GLOBAL_REQUESTED_MEMORY_BYTES`, `MAX_BACKEND_REQUESTED_MEMORY_BYTES` | Caps the sum of requested memory across all active executions globally and per selected backend/host. |
| Aggregate requested disk ceilings | `MAX_GLOBAL_REQUESTED_DISK_BYTES`, `MAX_BACKEND_REQUESTED_DISK_BYTES` | Caps the sum of requested disk across all active executions globally and per selected backend/host. |
| Per-execution maxima | `MAX_EXECUTION_CPU_QUOTA`, `MAX_EXECUTION_MEMORY_BYTES`, `MAX_EXECUTION_DISK_BYTES` | Rejects a single run whose requested resource tuple is too large before provisioning starts. |
| Provisioning-rate window | `PROVISIONING_RATE_WINDOW_SECONDS`, `MAX_GLOBAL_PROVISIONINGS_PER_WINDOW`, `MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW`, `MAX_PROJECT_PROVISIONINGS_PER_WINDOW` | Applies global, per-account, and per-project backpressure so a queue burst cannot provision unbounded cloud resources. |

Example:

```env
MAX_GLOBAL_REQUESTED_CPU_QUOTA=8000000
MAX_BACKEND_REQUESTED_CPU_QUOTA=2000000
MAX_GLOBAL_REQUESTED_MEMORY_BYTES=137438953472
MAX_BACKEND_REQUESTED_MEMORY_BYTES=34359738368
MAX_GLOBAL_REQUESTED_DISK_BYTES=274877906944
MAX_BACKEND_REQUESTED_DISK_BYTES=68719476736
MAX_EXECUTION_CPU_QUOTA=400000
MAX_EXECUTION_MEMORY_BYTES=17179869184
MAX_EXECUTION_DISK_BYTES=4294967296
PROVISIONING_RATE_WINDOW_SECONDS=600
MAX_GLOBAL_PROVISIONINGS_PER_WINDOW=25
MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW=10
MAX_PROJECT_PROVISIONINGS_PER_WINDOW=5
```

### Optional infrastructure spend thresholds

Infrastructure spend thresholds are **optional** Paid-owned safety controls.
They default to `0` (disabled) and are not required for boot — unlike the
resource and provisioning-rate ceilings above — but once set to a positive
integer they are enforced fail-closed on the same pre-provisioning admission
path (see [`docs/intent/infrastructure-spend-thresholds/`](intent/infrastructure-spend-thresholds/)
and [RDR-061](rdrs/RDR-061-infrastructure-safety-and-audit.md)).

| Category | Settings | Purpose |
|---|---|---|
| Host pricing | `INFRA_SPEND_RATE_CENTS_PER_HOUR` | Host-priced hourly rate used to account and project infrastructure spend. A per-host override uses the same key with a `__<HOST>` suffix (e.g. `INFRA_SPEND_RATE_CENTS_PER_HOUR__GPU_HOST_1`). |
| Projection horizon | `INFRA_SPEND_PROJECTION_SECONDS` | How far ahead the candidate run's projected spend reaches, clipped to the remaining window. Defaults to `3600`. |
| Global thresholds | `MAX_GLOBAL_INFRA_SPEND_HOURLY_CENTS`, `MAX_GLOBAL_INFRA_SPEND_DAILY_CENTS` | A projected breach parks queued runs until the window resets. A **daily** global breach escalates to an automatic global emergency `ExecutionControl` that clears itself once the daily window recovers. |
| Account thresholds | `MAX_ACCOUNT_INFRA_SPEND_HOURLY_CENTS`, `MAX_ACCOUNT_INFRA_SPEND_DAILY_CENTS` | A projected breach parks the account's queued runs until the window resets. |
| Project thresholds | `MAX_PROJECT_INFRA_SPEND_HOURLY_CENTS`, `MAX_PROJECT_INFRA_SPEND_DAILY_CENTS` | A projected breach parks the project's queued runs until the window resets. |
| Runner thresholds | `MAX_RUNNER_INFRA_SPEND_HOURLY_CENTS`, `MAX_RUNNER_INFRA_SPEND_DAILY_CENTS` | A projected breach fails that runner fast on the queue path and reroutes to another healthy runner when available. |

```env
INFRA_SPEND_RATE_CENTS_PER_HOUR=90
INFRA_SPEND_PROJECTION_SECONDS=3600
MAX_GLOBAL_INFRA_SPEND_HOURLY_CENTS=5000
MAX_GLOBAL_INFRA_SPEND_DAILY_CENTS=50000
MAX_ACCOUNT_INFRA_SPEND_HOURLY_CENTS=1000
MAX_ACCOUNT_INFRA_SPEND_DAILY_CENTS=10000
MAX_PROJECT_INFRA_SPEND_HOURLY_CENTS=250
MAX_PROJECT_INFRA_SPEND_DAILY_CENTS=2500
MAX_RUNNER_INFRA_SPEND_HOURLY_CENTS=100
MAX_RUNNER_INFRA_SPEND_DAILY_CENTS=1000
```

Provider quotas, budgets, and billing alarms remain **defense-in-depth
backstops**: they are expected to exist, but Paid enforces its own thresholds
before provider provisioning starts rather than relying on provider-side
controls as the primary enforcement model.

### Failure message

When a required setting is missing, boot aborts with a message like:

```
Production configuration validation failed. Resolve all of the following required settings and restart:
- database: database connection (set DATABASE_URL or PAID_DATABASE_PASSWORD)
- qdrant_api_key: QDRANT_API_KEY (or qdrant.api_key credential)

See docs/PRODUCTION_CONFIG.md for the complete required environment variable list.
```

## Warned settings (dev defaults, logged not fatal)

These default to development values. A production deploy **should** override
them; leaving the default logs a warning at boot but does not stop the process.

| Setting | Default | Warning condition | Production value |
|---|---|---|---|
| `TEMPORAL_ADDRESS` / `TEMPORAL_HOST` | `localhost:7233` | resolves to a localhost address | your Temporal server, e.g. `temporal.internal:7233` |
| `REDIS_URL` | (localhost fallback) | unset or resolves to localhost | your Redis, e.g. `redis://redis.internal:6379/0` |
| `QDRANT_URL` | `http://localhost:6333` | resolves to localhost | your Qdrant, e.g. `http://qdrant.internal:6333` |
| `CONTAINER_BACKEND` | `local` | `local` and no Docker socket detected | mount `/var/run/docker.sock`, or set to `remote`/`swarm`/`multi` |
| `WORKSPACE_ROOT` | `/var/paid/workspaces` | path not writable | a writable host path (only needed for legacy worktree bind-mount execution; named-volume clones are the default) |
| `SCREENSHOTS_S3_*` | (unconfigured) | screenshots storage not configured | `SCREENSHOTS_S3_BUCKET`, `SCREENSHOTS_S3_REGION`, `SCREENSHOTS_S3_ACCESS_KEY_ID`, `SCREENSHOTS_S3_SECRET_ACCESS_KEY` |

> A `localhost` value is any of `localhost`, `127.0.0.1`, `0.0.0.0`, or `::1`,
> detected in either `host:port` form or a full `scheme://host:port/...` URL.

## Single-server Kamal deployments

Existing deployments that already set the documented variables continue to work
unchanged. The minimum Kamal environment for the validator to pass is:

```env
PAID_DATABASE_PASSWORD=...        # or DATABASE_URL
QDRANT_API_KEY=...                # or qdrant.api_key credential
TEMPORAL_ADDRESS=temporal:7233    # the compose/kamal service DNS name (not localhost)
REDIS_URL=redis://redis:6379/0    # if Redis-backed features are used
QDRANT_URL=http://qdrant:6333
MAX_GLOBAL_REQUESTED_CPU_QUOTA=8000000
MAX_BACKEND_REQUESTED_CPU_QUOTA=2000000
MAX_GLOBAL_REQUESTED_MEMORY_BYTES=137438953472
MAX_BACKEND_REQUESTED_MEMORY_BYTES=34359738368
MAX_GLOBAL_REQUESTED_DISK_BYTES=274877906944
MAX_BACKEND_REQUESTED_DISK_BYTES=68719476736
MAX_EXECUTION_CPU_QUOTA=400000
MAX_EXECUTION_MEMORY_BYTES=17179869184
MAX_EXECUTION_DISK_BYTES=4294967296
PROVISIONING_RATE_WINDOW_SECONDS=600
MAX_GLOBAL_PROVISIONINGS_PER_WINDOW=25
MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW=10
MAX_PROJECT_PROVISIONINGS_PER_WINDOW=5
```

Kamal injects these per role from `.kamal/secrets`; `RAILS_MASTER_KEY` is always
required. The `web`, `job`, and `worker_*` roles each boot Rails in the
production environment and are each validated independently.

## Where each setting is resolved

To keep the production contract explicit, the validator is the single consumer
that checks it, but the values are resolved through the existing accessors so
the contract stays in sync with how the app actually reads configuration:

| Check | Resolved via |
|---|---|
| Database | `ENV["DATABASE_URL"]`, `ENV["PAID_DATABASE_PASSWORD"]`, `ENV["DB_HOST"]` (`config/database.yml`) |
| Temporal address | `Paid.temporal_address` (`config/initializers/temporal.rb`) |
| Redis URL | `ENV["REDIS_URL"]` (`config/initializers/rails_performance.rb`, `ClaudeLoginSessions::Coordination`) |
| Qdrant URL | `Paid.qdrant_url` (`config/initializers/qdrant.rb`) |
| Qdrant API key | `Rails.application.credentials.dig(:qdrant, :api_key)` or `ENV["QDRANT_API_KEY"]` |
| Workspace root | `Rails.application.config.x.workspace_root` (`config/application.rb`) |
| Container backend | `ENV["CONTAINER_BACKEND"]`, `ENV["DOCKER_HOST"]` (`config/initializers/container_backend.rb`) |
| Screenshots storage | `ArtifactStorage.configured?` (`app/services/artifact_storage.rb`) |

## Testing the validator

The validator is a pure, injectable object. See
`spec/services/config/production_validator_spec.rb` for the full coverage:

- all-present — boot succeeds, no warnings;
- each-missing — each required setting, removed in turn, fails boot naming it;
- localhost-in-production — development defaults produce warnings, not failures.
