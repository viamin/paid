---
parent: PAID
prefix: ACCOUNT-ADMIN
---

# Low-Level Design: Account Administration

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the operator-console and customer account-administration
> behavior that shipped from RDR-026.

## Purpose

Paid now has two distinct account-administration surfaces:

- an operator-only backoffice under `/admin`
- a customer-facing account administration area under the normal product UI

The design goal is to keep those boundaries explicit. Global operator powers
must not leak to ordinary account owners/admins, while customer account
management must remain available without exposing the operator console.

## Shipped behavior

The operator surface uses Avo with explicit route gating. Anonymous users and
non-operators are denied before they can use the console, even if they are
account owners or admins in the product RBAC model.

Sensitive account lifecycle changes are exposed as explicit actions rather than
free-form destructive CRUD. Operators can suspend, reactivate, or deactivate an
account through dedicated Avo actions that require a single selected account
and emit structured success logs.

The customer-facing account surface remains separate from `/admin`. It loads
memberships, projects, billing summaries, compliance/operations/adoption
dashboards, and recent account activity into the normal account UI. Viewers may
read the page, while mutating membership or account settings still follows the
product RBAC rules.

Audit visibility is part of that customer surface: recent activity is rendered
in the UI and exportable as JSON so account owners/admins can inspect tenant
history without operator access.

## What this is not

- **Not a shared operator/customer admin role.** Product account ownership does
  not imply `/admin` access.
- **Not raw destructive account CRUD.** Lifecycle transitions are explicit
  actions with model constraints and audit logging.
- **Not the GitHub App setup flow.** Operator-only App setup lives under the
  GitHub sync/auth segment even though it shares the `/admin` area.
