# EARS Specs: Development Tooling

> Testable claims for the developer-facing surfaces that ship with the local
> development environment. Status markers: `[x]` implemented · `[ ]` active gap
> · `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r DEV-TOOLING-001`).

- [x] **DEV-TOOLING-001** — When a developer runs the application in the
  development environment, the Rails app SHALL mount the PgHero dashboard at
  `/pghero` so the local Postgres database can be inspected from the running
  process without a separate client tool.
  *Code:* `config/routes.rb`, `Gemfile`, `config/pghero.yml`.
  *Test:* `spec/config/pghero_development_setup_spec.rb`.

- [x] **DEV-TOOLING-002** — The dashboard SHALL NOT be reachable outside the
  development environment: the `pghero` gem SHALL be declared in the Gemfile's
  `development` group only, the route SHALL be mounted only when
  `Rails.env.development?` is true, and the production image SHALL install
  without the development group.
  *Code:* `Gemfile`, `config/routes.rb`, `Dockerfile`.
  *Test:* `spec/config/pghero_development_setup_spec.rb`.

- [x] **DEV-TOOLING-003** — The dashboard SHALL inspect the application's
  development `primary` database by default, following `DATABASE_URL` and the
  worktree-aware development database name, and SHALL inspect the database
  named by `PGHERO_DATABASE_URL` when that variable is set.
  *Code:* `config/pghero.yml`.
  *Test:* `spec/config/pghero_development_setup_spec.rb`.

- [x] **DEV-TOOLING-004** — The repository SHALL document how to install,
  start, access, and configure the dashboard, including the optional
  `PGHERO_DATABASE_URL` environment variable and the fact that the dashboard
  is development-only.
  *Code:* `README.md`, `CONTRIBUTING.md`, `.env.example`.
  *Test:* `spec/config/pghero_development_setup_spec.rb`.
