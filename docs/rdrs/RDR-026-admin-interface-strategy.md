# RDR-026: Admin Interface Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-22
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: #2011 (Avo Operator Console), #2012 (User-Facing Account Administration)
- **Related RDRs**: [RDR-010](RDR-010-multi-tenancy-rbac.md) (Multi-Tenancy and RBAC), [RDR-024](RDR-024-multi-tenancy-isolation-strategy.md) (Multi-Tenancy Isolation Strategy), [RDR-018](RDR-018-billing-aggregation.md) (Billing Aggregation)

## Problem Statement

Paid has account-scoped data and explicit RBAC models (`Account`, `User`, `AccountMembership`, `ProjectMembership`, `TenantSetting`), but no administrative interface for creating, editing, suspending, or inspecting accounts and users after signup. The current Devise registration flow creates the initial account and user, while operational fixes still require console access or one-off code.

This leaves two separate needs:

1. **Operator administration**: maintainers need a safe internal backoffice for inspecting and correcting tenant state.
2. **User-facing account administration**: account owners and admins eventually need product-grade team, billing, and account settings workflows.

The immediate decision is whether to build custom CRUD screens now or adopt an off-the-shelf Rails admin engine for the operator surface.

## Context

### Current State

- Authentication uses Devise.
- Authorization uses Pundit and explicit membership tables.
- Product-facing Pundit policies already distinguish account owners/admins from members/viewers, but those policies are not sufficient for a global operator console.
- RDR-024 already identifies missing tenant lifecycle/provisioning work and lists "Add admin UI for account lifecycle management" as future enforcement work.
- The roadmap tracks tenant onboarding flow design (#733), but does not yet describe a user-facing account management project.

### Requirements

- Provide maintainers an internal UI for account/user inspection without blocking on a polished customer-facing settings area.
- Respect Paid's existing authorization model rather than introducing parallel role logic.
- Avoid exposing destructive raw database actions by default.
- Keep the eventual product UI separate from the operator backoffice.
- Minimize custom code until account-management workflows are clearer.

## Decision

Use **Avo** for Paid's internal operator admin console.

Avo should be mounted under an operator-only route (for example `/admin`) and configured to use Devise's `current_user`, a fail-closed operator access gate, and Paid's Pundit policies for resource actions. The first implementation should expose a narrow resource set:

- `Account`
- `User`
- `AccountMembership`
- `ProjectMembership`
- `TenantSetting`

The Avo console is an operator tool, not the final account-management product surface. Customer-facing account administration remains a separate roadmap project after Phase 4.

## Rationale

### Why Avo

- Avo integrates naturally with Rails applications and provides resource CRUD quickly.
- Paid already uses Pundit; Avo supports Pundit-based authorization.
- Avo gives a more maintainable internal-tool baseline than hand-building CRUD screens for every operational model.
- The Community edition can be evaluated for the initial narrow scope before committing to paid-tier features.
- Keeping the operator UI in an admin engine lets the main Hotwire UI stay focused on product workflows.

### Why Not Custom Rails UI First

Custom UI is appropriate for the eventual user-facing account administration project, but it is slower for internal operations. Building it first would force product decisions before the team has enough operational usage data.

### Why Not ActiveAdmin

ActiveAdmin is mature, Devise-friendly, MIT licensed, and has a Pundit adapter. It remains a credible fallback if Avo has licensing, Rails compatibility, or customization problems.

Avo is preferred because it offers a more modern resource-management experience and is likely to age better if the internal console grows beyond bare CRUD.

### Why Not RailsAdmin or Administrate

RailsAdmin and Administrate are viable, but they are not the best fit for Paid's expected mix of Pundit-aware resource management, custom actions, and potentially richer internal operational views.

## Architecture

### Boundaries

```
+---------------------------------------------------------------------------+
|                         ADMIN INTERFACE STRATEGY                          |
|                                                                           |
|  Operator Console (Avo)                                                   |
|  ----------------------                                                   |
|  - Internal maintainer/admin backoffice                                   |
|  - Fast CRUD and inspection for tenant/account state                      |
|  - Explicit lifecycle actions instead of raw dangerous deletes            |
|  - Uses Devise current_user + Pundit policies                             |
|                                                                           |
|  Product Account Admin (Native Rails UI)                                  |
|  ---------------------------------------                                  |
|  - Account owner/admin team management                                    |
|  - Invitations, membership roles, account settings, billing               |
|  - Polished Hotwire workflows for end users                               |
|  - Scheduled after Phase 4                                                |
+---------------------------------------------------------------------------+
```

### Authorization

The admin console must deny access unless the current user has an explicit operator-level permission. Account owners/admins must not automatically gain access to the global operator console.

The initial implementation should use the smallest explicit gate that fits the current data model, such as an environment-configured allowlist of operator user IDs/emails. If the allowlist is absent in production, `/admin` must fail closed. A later implementation may replace the allowlist with a dedicated `operator`/`super_admin` attribute or membership model.

Pundit remains responsible for resource-level actions inside Avo, but route-level operator authorization is mandatory before any Avo controller action runs. Account owners/admins should manage their own account through the later user-facing account admin UI.

### Resource Safety

The first Avo resource set should avoid raw destructive actions for sensitive records:

- Prefer suspend/reactivate/deactivate account actions over direct account deletion.
- Prefer membership removal/role change actions over direct user deletion.
- Hide or make read-only password digests, reset/confirmation/unlock tokens, encrypted credential columns, OAuth tokens, PATs, API keys, and auth/session blobs.
- Keep secrets and token material masked in index, show, form, export, and audit views.
- Log lifecycle actions using structured logs and, later, audit events.

## Implementation Plan

Implement Avo as a **single issue** unless the work uncovers a blocker that naturally needs separation. The issue should cover:

1. Add and configure Avo.
2. Confirm the chosen Avo edition/license supports the required auth, resource, and action surface; fall back to ActiveAdmin if it does not.
3. Mount the admin route behind a fail-closed operator-only gate.
4. Create initial resources for `Account`, `User`, `AccountMembership`, `ProjectMembership`, and `TenantSetting`.
5. Wire Devise `current_user` and Pundit integration for resource actions.
6. Disable or restrict dangerous destroy actions.
7. Add lifecycle actions where the underlying model APIs already exist.
8. Add request/system specs proving anonymous users, regular users, account members, account admins, and account owners are denied unless they are explicit operators.
9. Document the operator console boundary in the README or admin runbook.

If this issue grows too large, split only along clear boundaries:

- installation/auth shell,
- resource definitions,
- lifecycle actions,
- documentation/tests.

## User-Facing Account Admin Project

After Phase 4, add a native Rails/Hotwire account administration project for account owners and admins. That project should include:

- Account profile/settings editing
- User invitations and onboarding
- Membership role management
- Ownership transfer
- Account lifecycle requests where appropriate
- Tenant settings and quota visibility
- Billing plan/invoice visibility once billing models are fully wired

This surface should use Paid's normal product UI patterns, not Avo.

## Validation

- Non-operators cannot access `/admin`.
- Account owners/admins without explicit operator permission cannot access `/admin`.
- Operators can view the initial resource set.
- Sensitive fields are masked or hidden.
- The selected Avo edition/license supports the required route gate, resource authorization, field controls, and lifecycle actions.
- Account lifecycle actions respect the operator gate and existing lifecycle service/model constraints.
- Cross-tenant actions are only available through the operator-gated console and are logged with actor, target account, action, and outcome.
- User-facing routes remain unchanged.

## Risks

| Risk | Mitigation |
|------|------------|
| Admin console bypasses app authorization | Add route-level operator gate, configure Pundit integration, and add denial specs for account owners/admins who are not operators |
| Raw CRUD allows destructive production mistakes | Disable dangerous actions by default; add explicit lifecycle actions |
| Avo licensing/features are insufficient | Start with Community edition; fall back to ActiveAdmin if needed |
| Operator UI becomes accidental product UI | Keep `/admin` route internal; roadmap native account admin separately |
| Sensitive credentials leak in admin pages | Hide password/token/encrypted/auth fields from index, show, form, export, and audit surfaces |

## References

- [Avo documentation](https://docs.avohq.io/)
- [ActiveAdmin authorization adapter](https://activeadmin.info/13-authorization-adapter.html)
- [RDR-010: Multi-Tenancy and RBAC](RDR-010-multi-tenancy-rbac.md)
- [RDR-024: Multi-Tenancy Isolation Strategy](RDR-024-multi-tenancy-isolation-strategy.md)
