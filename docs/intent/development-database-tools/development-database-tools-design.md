---
parent: PAID
prefix: DEV-DB-TOOLS
---

# Low-Level Design: Development Database Tools

## Purpose

Paid developers need a local, browser-based view of PostgreSQL health and query
activity while diagnosing development behavior. The tool must use the same
development database connection as Rails and must not become part of the
production application or deployment surface.

## PgHero integration

PgHero is a development-only Bundler dependency. Rails mounts its engine at
`/pghero` only when `Rails.env.development?` and the development gem is loaded.
The engine reads the normal Rails database configuration, including an explicit
`DATABASE_URL`, so no PgHero-specific credentials or service are required.

Developers start the normal stack with `bin/dev` (or `docker compose up --build`)
and visit `http://localhost:3000/pghero`. PgHero inspects the local PostgreSQL
database selected by the development environment; it does not start an extra
database service.

## Production boundary

The PgHero gem remains in Bundler's `development` group and its route has an
explicit development-environment guard. Production does not load the gem, mount
the engine, require an environment variable, or change deployment configuration.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Dashboard integration | Mount PgHero in the Rails development process | Standalone PgHero process; custom query UI | The mounted engine follows the existing development-dashboard convention and reuses Rails' database configuration without another process or credentials. |
| Environment boundary | Development Bundler group and route guard | Mount in all environments; production configuration switch | Database introspection is a local developer aid and should not enlarge the production attack or operations surface. |

## References

- [High-Level Design](../../high-level-design.md)
- [PgHero](https://github.com/ankane/pghero)
