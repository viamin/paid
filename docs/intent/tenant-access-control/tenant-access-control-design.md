---
parent: PAID
prefix: TENANT-ACCESS
---

# Low-Level Design: Tenant Access Control

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented membership-authorization behavior described
> in `docs/rdrs/RDR-010-multi-tenancy-rbac.md`.

## Purpose

Paid's tenant model is not just row isolation. Product actions are gated by
account membership, project membership, and Pundit policies that apply those
roles consistently across request handlers.

## Shipped Behavior

The shipped RBAC model uses explicit `AccountMembership` and
`ProjectMembership` records plus Pundit policies layered on top of the current
tenant context.

Base policies enforce same-account visibility and same-account policy scopes.
That means a user from another account cannot read or enumerate tenant-scoped
records even if they can guess IDs.

Role-sensitive actions build on that baseline. Account owners and admins may
update account-scoped resources, owners alone hold destructive or billing-only
powers, and project actions such as agent execution or issue management also
permit project-specific roles when the user is still inside the same account.

## What This Is Not

- **Not operator-console authorization.** Global `/admin` access is a separate
  fail-closed surface covered by the account-administration segment.
- **Not a substitute for RLS.** Pundit is the product-level authorization
  layer; PostgreSQL RLS remains the database isolation backstop.
