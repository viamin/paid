# RDR-029: Multi-Tenancy Preparation

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-06
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #740 (Multi-Tenancy Phase 3.7), #729, #730, #731, #732, #733
- **Related RDRs**: RDR-010 (Multi-Tenancy and RBAC), RDR-024 (Isolation Strategy), RDR-018 (Billing Aggregation)
- **Related Tests**: `spec/services/accounts/provision_spec.rb`, `spec/models/concerns/tenant_enforcement_spec.rb`

## Problem Statement

Phase 3.7 requires the multi-tenancy architecture to be fully documented and production-ready for multiple teams/organizations. While individual components exist (Account model, TenantContext, TenantSetting, billing models, onboarding flow), they need to be unified into a cohesive, documented architecture with clear provisioning, enforcement, and lifecycle management.

## Context

### Existing Foundation

The multi-tenancy infrastructure was built incrementally across Phases 1-2:

| Component | Status | Location |
|-----------|--------|----------|
| Account model with lifecycle | Implemented | `app/models/account.rb` |
| TenantContext (RLS session vars) | Implemented | `app/services/tenant_context.rb` |
| TenantScoped concern | Implemented | `app/models/concerns/tenant_scoped.rb` |
| TenantSetting (per-tenant config) | Implemented | `app/models/tenant_setting.rb` |
| Database RLS policies | Implemented | `db/structure.sql` |
| Billing models | Implemented | `app/models/billing_*.rb` |
| Billing aggregation | Implemented | `app/services/billing/` |
| Onboarding flow | Implemented | `app/services/onboarding/` |
| RBAC (AccountMembership) | Implemented | `app/models/account_membership.rb` |

### Gaps Identified

1. **No unified provisioning service** — account creation, tenant settings, and onboarding are separate steps with no single entry point
2. **No status enforcement** — suspended/deactivated accounts can still make requests
3. **No plan-based resource limits** — billing plans define pricing but don't enforce feature gates
4. **No architectural overview document** — components are documented individually but not as a system

## Decision

Implement the remaining integration layer that connects existing components into a production-ready multi-tenancy system:

1. **Unified provisioning** — `Accounts::Provision` service handles account creation, tenant setting initialization, onboarding start, and default billing plan assignment in a single transaction
2. **Status enforcement** — `TenantEnforcement` concern blocks actions for suspended/deactivated accounts at the controller layer
3. **Plan-based limits** — `TenantSetting` uses plan tier to set resource limit defaults

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Request Flow                                    │
│                                                                        │
│  Request → ApplicationController                                       │
│              │                                                         │
│              ├─ with_current_attributes (sets TenantContext)           │
│              ├─ TenantEnforcement (checks account status)              │
│              └─ Pundit (authorizes action)                             │
│                                                                        │
├──────────────────────────────────────────────────────────────────────┤
│                        Data Layer                                       │
│                                                                        │
│  Application Scoping (primary)                                         │
│    └─ TenantScoped concern → belongs_to :account + for_tenant scope   │
│                                                                        │
│  Database RLS (defense-in-depth)                                       │
│    └─ paid_current_account_id() + tenant_isolation policies           │
│                                                                        │
├──────────────────────────────────────────────────────────────────────┤
│                     Configuration                                      │
│                                                                        │
│  TenantSetting (account-level)                                         │
│    ├─ Guardrails: max_concurrent_runs, max_tokens_per_run             │
│    ├─ Resource limits: max_projects, max_users                         │
│    ├─ Provider preferences: model_preferences, api_key_ids            │
│    ├─ Quality thresholds                                               │
│    ├─ Agent settings                                                   │
│    ├─ Worker settings                                                  │
│    └─ Feature flags                                                    │
│                                                                        │
├──────────────────────────────────────────────────────────────────────┤
│                        Billing                                          │
│                                                                        │
│  BillingPlan → BillingPeriod → BillingInvoice → BillingLineItem       │
│                     │                                                  │
│                     └─ AggregateTenantUsage (on-demand from TokenUsage)│
│                                                                        │
├──────────────────────────────────────────────────────────────────────┤
│                       Lifecycle                                         │
│                                                                        │
│  Provision → Active ←→ Suspended → Deactivated                        │
│     │                                                                  │
│     ├─ Accounts::Provision (creates account + settings + onboarding)  │
│     ├─ Onboarding::StartOnboarding (wizard steps)                     │
│     └─ Onboarding::ProvisionDefaults (prompts, style guides)          │
│                                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Data Isolation Strategy

### Primary: Application-Level Scoping

All tenant-scoped models include `TenantScoped` which provides:

- `belongs_to :account` association
- `for_tenant(account)` scope
- `for_current_tenant` scope (uses `Current.account`)

Controllers use `current_account` to scope all queries. Pundit policies enforce authorization.

### Secondary: Database RLS (Defense-in-Depth)

PostgreSQL RLS policies on all tenant-scoped tables check:

1. `paid_tenant_bypass()` — allows system access (migrations, background jobs)
2. `paid_current_account_id()` — matches the session-level account ID set by `TenantContext.apply!`

This prevents data leaks even if application code has scoping bugs.

### Isolation Guarantee

Every request follows this path:

1. `ApplicationController#with_current_attributes` → sets `Current.account` and `TenantContext`
2. PostgreSQL session variable `paid.current_account_id` set to account ID
3. RLS policies filter all queries to current tenant
4. Pundit policies verify user has access to specific resources

## Plan-Based Resource Limits

| Plan | Max Projects | Max Users | Max Concurrent Runs | Max Tokens/Run |
|------|-------------|-----------|--------------------|--------------------|
| trial | 3 | 5 | 2 | 5,000,000 |
| free | 5 | 10 | 3 | 5,000,000 |
| professional | 50 | 25 | 10 | 10,000,000 |
| enterprise | unlimited | unlimited | 100 | unlimited |

These are encoded as defaults in `TenantSetting::PLAN_DEFAULTS` and applied at provisioning time.

## Tenant Onboarding Flow

```
Accounts::Provision.call(name:, owner_email:, plan:)
  ├─ Create Account (with slug generation)
  ├─ Create TenantSetting (with plan-based defaults)
  ├─ Create BillingPlan (based on account plan)
  ├─ Onboarding::StartOnboarding (create wizard steps)
  └─ Return provisioned account

Onboarding Steps:
  1. account_profile — Set org name, avatar
  2. github_token — Connect GitHub account
  3. first_project — Import first repository
  4. configure_defaults — Set preferences (triggers ProvisionDefaults)
```

## Billing Aggregation Design

Billing follows an on-demand aggregation model:

1. **Token usage records** accumulate in `token_usages` during normal operation
2. **Period close** triggers `Billing::AggregateTenantUsage` to summarize the period
3. **Charge calculation** applies plan rates to usage totals
4. **Invoice generation** creates line items for base rate, overages, and adjustments
5. **External integration** via `external_id` field for Stripe/payment processor

Billing periods transition: `open → closed → invoiced`

## Implementation Plan

### Delivered in This PR

1. `Accounts::Provision` service — unified provisioning
2. `TenantEnforcement` concern — status-based access control
3. Plan-based defaults in `TenantSetting`
4. This RDR documenting the complete architecture
5. Tests for all new code

### Future Work

- Admin UI for account lifecycle management
- Automated suspension on billing failure
- Usage alerting (approaching limits)
- Self-service plan upgrades
- Data export for deactivated accounts

## Validation

### Testing Approach

- Unit tests for `Accounts::Provision` service
- Unit tests for `TenantEnforcement` concern
- Existing tests for `TenantContext`, `TenantSetting`, billing, onboarding
- Cross-tenant isolation spec (`spec/system/cross_tenant_isolation_spec.rb`)

### Rollback Strategy

All changes are additive. The `TenantEnforcement` concern can be removed from `ApplicationController` with no side effects. The provisioning service is new code with no existing callers to break.

## References

- RDR-010: Multi-Tenancy and RBAC (foundational architecture)
- RDR-024: Multi-Tenancy Isolation Strategy (isolation decisions)
- RDR-018: Billing Aggregation (billing system design)
- `app/services/tenant_context.rb` — Context management
- `app/models/tenant_setting.rb` — Per-tenant configuration
- `app/services/billing/` — Billing services
- `app/services/onboarding/` — Onboarding services
