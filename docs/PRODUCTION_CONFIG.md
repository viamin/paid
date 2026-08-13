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
| Screenshots storage | `Screenshots::Storage.configured?` (`app/services/screenshots/storage.rb`) |

## Testing the validator

The validator is a pure, injectable object. See
`spec/services/config/production_validator_spec.rb` for the full coverage:

- all-present — boot succeeds, no warnings;
- each-missing — each required setting, removed in turn, fails boot naming it;
- localhost-in-production — development defaults produce warnings, not failures.
