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
infrastructure. Rails remains on `db/schema.rb`, with PostgreSQL functions and
triggers handled through `fx` where applicable.

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
