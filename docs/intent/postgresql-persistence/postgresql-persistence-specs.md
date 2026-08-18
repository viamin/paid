# EARS Specs: PostgreSQL Persistence

> Testable claims for the implemented PostgreSQL persistence layer. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r POSTGRESQL-PERSISTENCE-001`).

## Tenant Isolation

- [x] **POSTGRESQL-PERSISTENCE-001** — Tenant-scoped Paid data SHALL be
  isolated in PostgreSQL by row-level security policies keyed from
  `paid.current_account_id`, and tenant-scoped reads without tenant context
  SHALL return no tenant rows.
  *Tests:* `spec/security/tenant_context_spec.rb`.
  *Code:* `EnableTenantRowLevelSecurity`, `TenantContext`.

- [x] **POSTGRESQL-PERSISTENCE-002** — The application runtime SHALL reject
  PostgreSQL roles with `SUPERUSER` or `BYPASSRLS` privileges so application
  traffic cannot silently bypass tenant RLS.
  *Code:* `Database::RuntimeRoleGuard`.

- [x] **POSTGRESQL-PERSISTENCE-006** — Tenant RLS policies SHALL reject
  cross-tenant writes for direct account rows, join rows, and project-owned
  records instead of relying on application checks alone.
  *Tests:* `spec/security/tenant_context_spec.rb`.
  *Code:* `EnableTenantRowLevelSecurity`, `TenantContext`.

- [x] **POSTGRESQL-PERSISTENCE-008** — When a data migration reads or writes
  account-less global records on tenant-scoped tables, it SHALL run under
  `TenantContext.with_system_access` so row locks and writes are not rejected by
  the tenant write policies that deliberately exclude global rows.
  *Tests:* `spec/migrations/sync_issue_implementation_prompt_remove_safety_rules_spec.rb`.
  *Code:* `SyncIssueImplementationPromptRemoveSafetyRules`,
  `SyncCreateGithubIssuePromptClarificationFix`, `TenantContext`.

## Encrypted and Audited Credentials

- [x] **POSTGRESQL-PERSISTENCE-003** — Stored GitHub tokens SHALL be encrypted
  at rest and their configuration records SHALL retain change history through
  Logidze.
  *Tests:* `spec/models/github_token_spec.rb`.
  *Code:* `GithubToken`.

## PostgreSQL-Native Search

- [x] **POSTGRESQL-PERSISTENCE-004** — Knowledge full-text search SHALL use
  PostgreSQL-maintained `tsvector` data and concurrent GIN/trigram indexes so
  existing rows are searchable after deploy without requiring a separate search
  service.
  *Code:* `AddTextSearchToKnowledge`.

- [D] **POSTGRESQL-PERSISTENCE-005** — When operational scale thresholds are
  reached, the persistence layer SHALL document the shipped partitioning,
  retention, replica, and query-observability strategy in this segment.

## Canonical Schema Dump

- [x] **POSTGRESQL-PERSISTENCE-007** — Replaying migrations in CI SHALL dump a
  `db/schema.rb` identical to the checked-in canonical schema, and PostgreSQL
  helper functions included in the schema dump SHALL be backed by versioned
  `fx` definitions instead of unmanaged auto-discovery.
  *Tests:* `spec/config/ci_database_workflow_file_spec.rb`,
  `spec/migrations/canonicalize_schema_dump_metadata_spec.rb`.
  *Code:* `CanonicalizeSchemaDumpMetadata`, `db/functions/paid_current_account_id_v01.sql`,
  `db/functions/paid_tenant_bypass_v01.sql`.
