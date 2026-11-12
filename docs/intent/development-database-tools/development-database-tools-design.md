---
parent: PAID
prefix: DEVELOPMENT-DATABASE-TOOLS
---

# Low-Level Design: Development Database Tools

## Purpose

Paid developers need a local, read-only database inspection surface without
adding a production service or changing production deployment configuration.

## PgHero

PgHero is a development-only Rails engine. Bundler installs it only in the
development group, and the route mounts only when the engine constant is
available. A development Rails process, including the existing Compose `web`
service and `bin/dev`, therefore exposes the dashboard at `/pghero` using the
same development database connection as the application.

Production does not install the gem or mount the route. PgHero needs no
separate container, database, credential, or environment variable: it uses
Paid's existing Rails database configuration.

## Verification

The repository configuration spec asserts the development-only dependency and
route, the documented startup/access workflow, and the absence of a production
dependency. The documented URL remains inspectable by a developer running the
existing local stack.
