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

Tenant isolation is enforced in PostgreSQL with helper functions driven by
`paid.current_account_id` and `paid.bypass_tenant_rls`. The application also
guards against unsafe runtime roles that would bypass those policies. The
shipped policy set does not just hide rows on reads; it also rejects
cross-tenant join rows and direct-account writes whose foreign keys point at a
different tenant.

Sensitive GitHub tokens are encrypted at rest through Rails encrypted
attributes, and the token records retain change history through Logidze.

Knowledge search uses PostgreSQL text-search features (`tsvector`, `pg_trgm`,
GIN indexes, trigger-maintained search vectors) for the shipped full-text path.

## Deferred Work

Scale-triggered follow-ups identified in the RDR remain deferred: partitioning
large operational tables, explicit read-replica criteria, retention/archival
policies, and `pg_stat_statements` monitoring. Those are operational evolution
steps, not blockers to the implemented PostgreSQL foundation.
