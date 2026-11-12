---
parent: PAID
prefix: DEVELOPMENT-DATABASE-INSPECTION
---

# Low-Level Design: Development Database Inspection

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment provides local database inspection without changing the production
> application or deployment runtime.

## Purpose

Developers need a browser-based view of their local PostgreSQL database while
debugging Paid. PgHero provides that view as a Rails engine using the same
development database connection as the application.

## Design

PgHero is a dependency in Bundler's `development` group only. Rails mounts its
engine at `/pghero` only when the development environment has loaded the
engine. The development guard keeps the route out of test and production
route sets; the Bundler group keeps the gem out of production bundles and
images.

The existing `bin/setup` and `bin/dev` workflow installs and starts the
integration. Docker Compose already starts the Rails web service in
development and provides its `DATABASE_URL`, so PgHero inspects that same
local Compose PostgreSQL database without a separate service or credentials.
Local developers use their configured `DATABASE_URL`; no PgHero-specific
environment variable is required.

## Verification Plan

`DEVELOPMENT-DATABASE-INSPECTION-001` is covered by a focused configuration
spec that verifies the development-only dependency, guarded route, and README
startup/access instructions. The actual local browser inspection is a human
criterion: the documented route is inspectable after a developer starts the
existing development stack with a reachable `DATABASE_URL`.

## Decisions & Alternatives

| Decision | Alternatives considered | Reason |
| --- | --- | --- |
| Mount PgHero in the Rails development process | Run a standalone PgHero container | The engine automatically shares Rails' configured local database and existing startup workflow, without another service to configure. |
| Use Bundler and route environment guards | Add PgHero to all environments | Development inspection must not add a production dependency, route, or deployment concern. |
