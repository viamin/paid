---
parent: PAID
prefix: POSTGRESQL-PERSISTENCE
---

# Low-Level Design: PostgreSQL Persistence

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented persistence foundation described in
> `docs/rdrs/RDR-003-database-selection.md`.

## Purpose

Paid uses PostgreSQL as the primary persistence technology for application data,
tenant isolation, background-job backing stores, and database-native search and
indexing features.

## Shipped Architecture

The application schema uses PostgreSQL features directly: JSONB columns, GIN and
trigram indexes, full-text search, row-level security, and database-backed job
infrastructure. Rails remains on `db/schema.rb`, which is the canonical schema
artifact. PostgreSQL functions and triggers are handled through versioned `fx`
definitions, and CI rejects migration paths that dump a different `schema.rb`
than the checked-in canonical copy. Schema dumps sort columns alphabetically
by name in every environment, independent of their physical PostgreSQL order.
A dump-only connection wrapper supplies sorted columns to Rails while preserving
its rendering of definitions, constraints, and the existing `fx` integration.
It omits the development-only `pg_stat_statements` extension from schema dumps
so local query monitoring does not become a production schema dependency.
The primary and cable databases own disjoint table sets. A static regression
check compares their checked-in schema files and rejects shared tables, so a
dump from a contaminated database cannot silently commit cable tables into
the primary schema.

Routine `bin/dev-update` setup and migration commands consume committed schema
artifacts without automatically dumping local database state back into them.
They set `PAID_SKIP_AUTO_SCHEMA_DUMP=1` only for those commands. Normal migration
development and explicit `db:schema:dump` retain Rails defaults. This prevents
local catalog differences from becoming auto-stashed edits that conflict with
later upstream migrations.

The complete-policy bootstrap repair is a frozen, transactional metadata
migration sourced from the migrated main policy catalog: 224 policies across
200 tables at revision `2fb3a7103`. It restores their full current predicates
and enable/force flags rather than replaying selected earlier migration
groups or treating the accounts policy as a completeness sentinel. Four
obsolete configuration-bundle policy variants are removed so they cannot
remain as permissive alternatives. Unrelated tables and their intentional
inactive or default-deny flags are untouched. No application rows are changed;
rollback does not reinstate missing or weaker security boundaries. Future
policy evolution remains in ordinary migrations and the canonical schema
dump, not a runtime policy-reinstallation mechanism.

Catalog parity does not override current migration intent. Strategy and
strategy-version policies retain the nonrecursive visibility established by
`FixStrategiesRlsInfiniteRecursion`: versions may read their strategy's scope,
but strategy visibility does not query versions or itself. Version ownership
is enforced separately by versioned `fx` triggers. A current version must
belong to its strategy, a parent version must belong to the same strategy,
and moving a version cannot invalidate existing current or parent references.
These structural guards also apply during explicit system access. Normal-role
zero-row reads cover every protected table, so a copied catalog cannot hide
recursive-policy failures behind isolated-table sampling.
Reference checks lock the referenced version against concurrent reassignment.
The repair refuses existing invalid references rather than modifying
application rows, and preserves the guards on rollback and schema bootstrap.

Corrective migration replay preserves current canonical table, index, foreign-key
and FX definitions alongside the tenant policy catalog. Reference-guard repair
replaces any already-installed FX triggers transactionally, so upgrading a
schema-loaded or newer database retains enforcement without duplicate-trigger
failures. Corrective rollback retains the current guards rather than
restoring weaker legacy enforcement.

Tenant isolation is enforced in PostgreSQL with helper functions driven by
`paid.current_account_id` and `paid.bypass_tenant_rls`. The application also
guards against unsafe runtime roles that would bypass those policies. The
tenant-context writer bypasses Rails's query cache for its parameterized
session-setting queries. The
database-backed CI workflows start their PostgreSQL service with the bootstrap
role, then create and use a dedicated non-superuser application role for Rails
database tasks. The shipped policy set does not just hide rows on reads; it also rejects
cross-tenant join rows and direct-account writes whose foreign keys point at a
different tenant. A project credential transition accepts either a GitHub token
or a GitHub App installation only when it belongs to the project's account.
Explicitly global catalog rows needed by a tenant workflow are exposed through
read-only policies; tenant mutations remain project-scoped.
CI grants its dedicated test runtime role `CREATEROLE` so
RLS regression specs can create and revoke their restricted test role. The CI
role remains explicitly `NOSUPERUSER` and `NOBYPASSRLS`, matching the runtime
guard's safety boundary. CI test connections default to the application's
explicit system-access setting so independently opened test connections retain
the harness context; tenant-isolation examples set the value false before
asserting scoped behavior.
The browser-test Rack boundary restores that baseline after the complete request
scope unwinds, including errors. It does not install global executor callbacks
that mutate pooled session state during unrelated work or fixture teardown.
The browser regression server handles one request at a time because transactional
fixtures pin a single PostgreSQL session across threads. Its Rack boundary and
ActionCable worker callbacks share a reentrant fixture-session lock: an entire
HTTP request or Cable unit, including tenant cleanup, completes before another
can change that session's tenant settings. This applies only to the test harness.
System teardown closes browser transports and drains Cable workers before Rails
unpins the fixture connection and removes its thread lock, preventing late Cable
cleanup from racing the example's tenant restoration or the next fixture.
Application concurrency tests use independent connections instead of interleaving
tenant settings on that shared session.

The container-runtime provisioner applies that same boundary to agent test
services: bootstrap credentials administer PostgreSQL, while each run receives
a separate `NOSUPERUSER NOBYPASSRLS` application role owning its isolated
database. `CREATEDB` and `CREATEROLE` support database setup and restricted-role
regression tests; they do not grant superuser or tenant-policy bypass.

Sensitive GitHub tokens are encrypted at rest through Rails encrypted
attributes, and the token records retain change history through Logidze.

Knowledge search uses PostgreSQL text-search features (`tsvector`, `pg_trgm`,
GIN indexes, trigger-maintained search vectors) for the shipped full-text path.

Migration replay tests isolate their DDL in rollback-only transactions. Testing
a historical rollback must restore the exact pre-example catalog, including
policies and enable/force flags added by later migrations; replaying only an
older migration list is not sufficient cleanup for a randomized suite.

Strategy lookup indexes retain `(decision_type, status)` and the unique
`(strategy_id, version)` index. A corrective migration removes their redundant
single-column prefixes concurrently, with concurrent rollback. Scoped strategy
uniqueness, single-active-version uniqueness, reference guards and row-security
policies remain intact.

## Deferred Work

Scale-triggered follow-ups identified in the RDR remain deferred: partitioning
large operational tables, explicit read-replica criteria, retention/archival
policies, and production `pg_stat_statements` monitoring. The development
PostgreSQL container preloads `pg_stat_statements` for PgHero's current query
stats; production monitoring remains operational evolution.
These steps are not blockers to the implemented PostgreSQL foundation.
