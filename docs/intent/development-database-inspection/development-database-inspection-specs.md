# EARS Specs: Development Database Inspection

> Testable claims for local PgHero access. Status markers: `[x]` implemented
> · `[ ]` active gap · `[D]` deferred.

- [x] **DEVELOPMENT-DATABASE-INSPECTION-001** — When a developer installs
  dependencies and starts Paid in development with `bin/setup` and `bin/dev`,
  the application SHALL make PgHero available at `/pghero` against the same
  `DATABASE_URL`, and the README SHALL document startup, access, and that no
  PgHero-specific environment variable is required.
  *Tests:* `spec/config/pg_hero_development_setup_spec.rb`.
  *Code:* `Gemfile`, `config/routes.rb`, `README.md`.

- [x] **DEVELOPMENT-DATABASE-INSPECTION-002** — PgHero SHALL be absent from
  production dependency and route configuration, so development inspection
  does not change production deployment behavior.
  *Tests:* `spec/config/pg_hero_development_setup_spec.rb`.
  *Code:* `Gemfile`, `config/routes.rb`.
