---
parent: PAID
prefix: DEV-TOOLING
---

# Low-Level Design: Development Tooling

> Companion to the high-level design (`docs/high-level-design.md`). This segment
> covers the developer-facing surfaces that ship with the local development
> environment and are deliberately absent from production. Today that surface
> is the PgHero dashboard for the local Postgres database.

## Purpose

Developers working on Paid need to answer questions about the local database
without leaving the dev stack: which query is slow, which connection is
holding a lock, which index is unused, how much space a table uses. The
application UI cannot answer those questions, and a separate client tool
means another install and another connection string to keep in sync.

Paid ships PgHero as a development-only Rails engine so the dashboard is
served by the process a developer is already running, reads the same database
the app reads, and disappears entirely in test and production.

## Shipped behavior

- **Gem declaration.** `pghero` is declared in the Gemfile's `development`
  group. Bundler therefore never loads it under `RAILS_ENV=test` or
  `RAILS_ENV=production`, and the production image (which installs with
  `BUNDLE_WITHOUT="development"`) does not ship the gem at all.
- **Route.** `config/routes.rb` mounts `PgHero::Engine` at `/pghero` behind
  `Rails.env.development?` and `defined?(PgHero::Engine)`. The environment
  check is the belt to the gem group's braces: even an environment that
  installs the development group does not expose the dashboard.
- **Connection.** `config/pghero.yml` points the dashboard at the app's
  development `primary` connection by resolving the `primary` Active Record
  spec. The dashboard therefore follows `DATABASE_URL`, `DB_HOST`, and the
  worktree-aware development database name without extra configuration.
- **Override.** `PGHERO_DATABASE_URL` replaces that connection when it is set.
  Developers use it to inspect a different database, or to connect with a role
  that can perform privileged operations such as terminating another user's
  backends.
- **Documentation.** `README.md` documents installation, startup, the URL, and
  the environment variable; `CONTRIBUTING.md` lists the endpoint among the
  common local endpoints; `.env.example` records the optional variable.

## Scope decisions

- **No separate service or container.** The dashboard runs inside the
  development-mode Rails process, matching how `rails_performance` and `dial`
  are mounted. A dedicated Compose service would need its own image pin, its
  own connection string, and its own lifecycle in `bin/dev`.
- **No authentication.** PgHero can kill queries and connections, but the
  dashboard is reachable only from a developer's own machine in the
  development environment, which is also where the database is reachable
  directly. Adding credentials would add a secret to the dev workflow for no
  added protection.
- **No production support.** A production instance would need its own
  connection, its own authorization, and an operational owner for a tool whose
  primary operations are destructive. The production contract stays in
  `docs/PRODUCTION_CONFIG.md`.
- **Development-only gem, not a runtime dependency.** Paid does not need the
  dashboard to run; the gem stays out of the default bundle group so it
  cannot be loaded by accident in a deployed environment.
