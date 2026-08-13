# RDR-024: Multi-Tenancy Isolation Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-17
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #729 (Multi-tenancy design), RDR-010 (Multi-Tenancy and RBAC)
- **Related Tests**: `spec/models/account_spec.rb`, `spec/models/tenant_setting_spec.rb`, `spec/models/concerns/tenant_scoped_spec.rb`

## Implementation Status

Implemented with material hardening beyond the original recommendation. Paid uses account lifecycle states, tenant settings, request-level tenant enforcement, explicit tenant scopes, database session tenant context, and broad forced PostgreSQL RLS. The implementation intentionally evolved from "application-level primary, RLS later" to a hybrid model with database-enforced tenant isolation.

## Problem Statement

Paid needs full multi-tenancy to support multiple organizations sharing a single deployment. The existing `Account` model provides basic data isolation via `account_id` foreign keys, but lacks:

1. **Tenant lifecycle management** — no way to suspend or deactivate accounts
2. **Tenant-level configuration** — operational settings (concurrency limits, resource quotas) live on `UserSetting` instead of the account
3. **Formalized isolation guarantees** — scoping relies on controller conventions, not enforced model-level defaults
4. **Tenant provisioning workflow** — no defined states for account creation, activation, suspension, or deletion

## Context

### Background

RDR-010 established row-level isolation with `account_id` foreign keys as the multi-tenancy pattern. This was the right choice for Phase 1 (single-team usage). Phase 3 (Scale) requires hardening this foundation for true multi-tenant SaaS operation.

### Current Architecture

```
┌─────────────────────────────────────────────┐
│                   Account                    │
│  name, slug, default_max_tokens_per_run      │
│  scheduler_paused_at                         │
├──────────────────┬──────────────────────────┤
│  AccountMembership│  Direct resources         │
│  (user ↔ role)    │  projects, github_tokens, │
│                   │  prompts, style_guides,   │
│                   │  integration_credentials, │
│                   │  mcp_server_definitions   │
└──────────────────┴──────────────────────────┘
```

**Tables with direct `account_id`**: `account_memberships`, `github_tokens`, `integration_credentials`, `linear_tokens`, `mcp_server_definitions`, `notifications`, `pre_commit_requirements`, `projects`, `prompts`, `style_guides`.

**Tables with indirect account scoping** (via `project_id → account_id`): `agent_runs`, `issues`, `cost_budgets`, `knowledge_artifacts`, `worktrees`, and ~20 more.

### Constraints

- PostgreSQL 15+ (single database instance)
- Rails 8.1 with Pundit authorization
- Existing `Account` model must remain backward-compatible
- No external multi-tenancy gems (acts_as_tenant) — keep dependency surface small

## Research Findings

### Isolation Strategy Evaluation

| Strategy | Isolation Level | Query Overhead | Migration Complexity | Cross-Tenant Queries | Operational Complexity |
|----------|----------------|----------------|---------------------|----------------------|----------------------|
| **Schema-per-tenant** | Strong (DDL) | None (search_path) | High (N schemas × M migrations) | Hard (cross-schema joins) | High (schema management) |
| **Row-Level Security (RLS)** | Strong (DB-enforced) | Low (policy checks) | Medium (policies per table) | Medium (policy bypass) | Medium (policy management) |
| **Application-level scoping** | Moderate (app-enforced) | None | Low (already done) | Easy (normal queries) | Low (Rails conventions) |

### Key Discoveries

1. **Schema-per-tenant** is overkill for Paid's scale. It adds operational complexity (running migrations across N schemas) without proportional benefit. Paid's data model is uniform across tenants.

2. **RLS** provides database-enforced isolation but requires `SET LOCAL` on every connection checkout and careful policy management. The existing Pundit + `current_account` pattern already provides equivalent authorization at the application layer.

3. **Application-level scoping** is already 90% implemented. The missing 10% is: (a) a model-level `default_scope` concern for `account_id`-bearing models, (b) tenant lifecycle states, and (c) tenant-level configuration.

4. **Hybrid approach** is optimal: keep application-level scoping as primary isolation, add a `TenantScoped` concern for consistent model-level defaults, and layer RLS as a future defense-in-depth option without depending on it.

## Decision

**Application-level scoping with formalized tenant lifecycle and configuration.**

Extend the existing `Account` model with:

1. A `status` enum for tenant lifecycle (active, suspended, deactivated)
2. A `TenantSetting` model for account-level operational configuration
3. A `TenantScoped` concern that enforces `account_id` scoping at the model level

### Why Not Schema-per-Tenant

- **Migration overhead**: Every `rails db:migrate` must run across all tenant schemas. With 100+ tenants, this becomes a deployment bottleneck.
- **Cross-tenant analytics**: Paid needs account-level dashboards that aggregate across projects — cross-schema joins are painful.
- **Existing investment**: All tables already have `account_id` columns. Switching to schemas would be a rewrite, not an evolution.

### Why Not RLS

- **Complexity without benefit**: RLS requires `SET LOCAL paid.current_account_id` on every connection checkout. The existing Pundit policies already enforce the same constraints at the application layer.
- **Testing difficulty**: RLS policies are invisible to the application — bugs in policies are harder to debug than bugs in Ruby code.
- **Future option**: RLS can be layered on later as defense-in-depth without changing the application code. The `account_id` column pattern is compatible with both approaches.

### Why Application-Level Scoping

- **Already implemented**: 90% of the scoping work is done via `current_account` and Pundit policies.
- **Testable**: Ruby-level scoping is visible in tests and debuggable with standard Rails tools.
- **Evolvable**: The pattern naturally extends to support tenant lifecycle and configuration.
- **Low risk**: No database-level changes to connection handling or query planning.

## Tenant Lifecycle Design

### States

```
                    ┌──────────┐
        create ───→ │  active   │
                    └────┬─────┘
                         │
                    suspend │ reactivate
                         ↓         ↑
                    ┌────┴─────┐
                    │ suspended │
                    └────┬─────┘
                         │
                  deactivate │
                         ↓
                    ┌──────────────┐
                    │  deactivated  │
                    └──────────────┘
```

| State | Behavior |
|-------|----------|
| `active` | Full access. All features enabled. |
| `suspended` | Read-only access. Agent runs blocked. New project creation blocked. Existing data visible. |
| `deactivated` | No access. Login blocked. Data retained for grace period. |

### Transitions

- **Active → Suspended**: Owner/admin action, or automated (billing failure, policy violation). Sets `suspended_at` timestamp.
- **Suspended → Active**: Owner/admin reactivation, or automated (billing resolved). Clears `suspended_at`.
- **Suspended → Deactivated**: Owner action or automated after grace period. Sets `deactivated_at`.
- **Deactivated → Active**: Admin-only reactivation (support process).

## Tenant-Level Configuration

### TenantSetting Model

Account-level operational configuration, analogous to `UserSetting` but scoped to the account. Settings here act as defaults/limits for all users in the account.

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `max_concurrent_runs` | integer | 10 | Max parallel agent runs across account |
| `max_projects` | integer | 50 | Max projects per account |
| `max_users` | integer | 25 | Max users per account |
| `max_tokens_per_run` | integer | 10,000,000 | Token limit per agent run |
| `max_monthly_cost_cents` | integer | nil | Monthly cost cap (nil = unlimited) |
| `allowed_runner_keys` | text[] | [] | Allowed AI runners (empty = all) |
| `features` | jsonb | {} | Feature flags/overrides for account |

### Setting Precedence

```
TenantSetting (account limit) > UserSetting (user preference)
```

User preferences cannot exceed account limits. For example, if `TenantSetting#max_concurrent_runs` is 5 and `UserSetting#max_concurrent_runs` is 10, the effective limit is 5.

## Migration Path

### From Current Account Model

The migration is additive — no breaking changes to the existing `Account` model:

1. Add `status` enum column (default: `active`) — existing accounts are automatically active
2. Add `suspended_at` and `deactivated_at` timestamps
3. Create `tenant_settings` table with 1:1 relationship to accounts
4. Add `TenantScoped` concern to models with `account_id`
5. Auto-create `TenantSetting` for existing accounts (like `UserSetting` pattern)

### Database Changes

```sql
-- Step 1: Add lifecycle columns to accounts
ALTER TABLE accounts ADD COLUMN status integer NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN suspended_at timestamp;
ALTER TABLE accounts ADD COLUMN deactivated_at timestamp;
CREATE INDEX index_accounts_on_status ON accounts (status);

-- Step 2: Create tenant_settings
CREATE TABLE tenant_settings (
  id bigserial PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES accounts(id),
  max_concurrent_runs integer NOT NULL DEFAULT 10,
  max_projects integer NOT NULL DEFAULT 50,
  max_users integer NOT NULL DEFAULT 25,
  max_tokens_per_run integer NOT NULL DEFAULT 10000000,
  max_monthly_cost_cents integer,
  allowed_runner_keys text[] DEFAULT '{}',
  features jsonb NOT NULL DEFAULT '{}',
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);
CREATE UNIQUE INDEX index_tenant_settings_on_account_id ON tenant_settings (account_id);
```

## Implementation Plan

### Phase 1: Foundation (This PR)

1. Add lifecycle columns to `accounts` table
2. Create `tenant_settings` table and model
3. Add `TenantScoped` concern for model-level scoping
4. Update `Account` model with lifecycle methods
5. Write tests for all new behavior

### Phase 2: Enforcement (Future PR)

1. Add middleware to check account status on every request
2. Block agent run creation for suspended accounts
3. Block login for deactivated accounts
4. Add admin UI for account lifecycle management

### Phase 3: Defense-in-Depth (Future PR)

1. Evaluate adding RLS policies as a secondary isolation layer
2. Add connection-level `SET LOCAL` for RLS enforcement
3. Audit all queries for missing account scoping

## Validation

### Testing Approach

- Unit tests for `Account` lifecycle transitions
- Unit tests for `TenantSetting` validations and defaults
- Unit tests for `TenantScoped` concern (default scope, validation)
- Integration tests for setting precedence (tenant vs. user)

### Rollback Strategy

All changes are additive. Rollback = revert migration (drop columns/table) + remove concern inclusion. No existing behavior is modified.

## References

- RDR-010: Multi-Tenancy and RBAC (foundational architecture)
- `app/models/user_setting.rb` — pattern for auto-created settings
- `app/models/current.rb` — request-scoped tenant context
- `app/controllers/application_controller.rb` — current_account pattern
