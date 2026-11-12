# EARS Specs: Development Database Tools

- [x] **DEVELOPMENT-DATABASE-TOOLS-001** — When a developer starts Paid through
  the existing Compose or `bin/dev` workflow, the development Rails process
  SHALL make PgHero available at `/pghero` against the application's local
  development database without requiring a new service or environment variable.
  *Code:* `Gemfile`, `config/routes.rb`.
  *Test:* `spec/config/development_database_tools_spec.rb`.

- [x] **DEVELOPMENT-DATABASE-TOOLS-002** — PgHero SHALL be installed and routed
  only for development; production dependencies, routes, and deployment
  configuration SHALL remain unchanged.
  *Code:* `Gemfile`, `config/routes.rb`.
  *Test:* `spec/config/development_database_tools_spec.rb`.

- [x] **DEVELOPMENT-DATABASE-TOOLS-003** — The developer documentation SHALL
  describe the existing startup workflows, the PgHero URL, and that no
  additional environment variable is required.
  *Code:* `README.md`.
  *Test:* `spec/config/development_database_tools_spec.rb`.
