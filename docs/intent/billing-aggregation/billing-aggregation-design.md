---
parent: PAID
prefix: BILLING-AGG
---

# Low-Level Design: Billing Aggregation

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the shipped billing behavior from the implemented billing
> aggregation RDR lineage, using the post-#3175 name `RDR-018a`.

## Purpose

Paid's billing layer aggregates tenant usage into account-facing billing
periods, invoices, and UI/API summaries without turning an external payment
provider into the application's source of truth.

This segment records the shipped brownfield contract after duplicate numbering
cleanup: account billing data is modeled and surfaced inside Paid, while
provider-specific charging and reconciliation remain intentionally out of scope.

## Shipped behavior

Billing aggregates existing usage data rather than dual-writing per-event
billing rows at runtime. Usage rolls up by account into billing periods and
invoices, then appears through two user-facing surfaces:

- the billing API under `/api/billing/*`
- the customer account-administration page

API access is policy-gated to billing-authorized account users. It exposes
usage summaries, periods, invoices with line items, and the active plan using
account-scoped lookups rather than global invoice access.

Managed billing period rollover is automated. `BillingPeriodManagementJob`
invokes the scheduled advancement flow, which closes due periods, opens the
next period, and issues invoices while emitting a structured completion log.

The account administration UI includes billing visibility in the same account
surface as memberships, projects, and recent activity. When billing is visible,
owners and admins can inspect the active plan, the current billing period,
recent invoices, and payment-sync follow-up state without leaving the account
settings workflow.

## Out of scope

The `RDR-018a` implementation intentionally stays provider-agnostic:

- no customer payment-method capture
- no Stripe-specific webhook ingestion contract in this segment
- no automatic collections, dunning, or tax workflows
- no unpaid-invoice enforcement beyond surfaced invoice/payment-sync state

Those remain separate product decisions, not gaps in this segment's shipped
intent.
