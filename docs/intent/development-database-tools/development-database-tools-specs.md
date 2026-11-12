# EARS Specs: Development Database Tools

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **DEV-DB-TOOLS-001** — When Paid runs in development with PgHero installed,
  the application SHALL mount PgHero at `/pghero` using the configured Rails
  database connection. When Paid runs outside development, it SHALL not mount
  PgHero or require PgHero production configuration.
  *Code:* `Gemfile`, `config/routes.rb`.
  *Test:* `spec/config/development_database_tools_spec.rb`.

- [x] **DEV-DB-TOOLS-002** — The local-development documentation SHALL describe
  PgHero setup, normal stack startup, the `/pghero` access URL, and the
  `DATABASE_URL` connection requirement.
  *Code:* `README.md`.
  *Test:* `spec/config/development_database_tools_spec.rb`.
