# RDR-018: Billing Aggregation System

- **Date**: 2026-04-17
- **Status**: Implemented
- **Type**: Feature Design
- **Priority**: P2
- **Related Issues**: #732
- **Related RDRs**: RDR-010 (Multi-Tenancy RBAC)

## Problem Statement

Paid needs a billing aggregation system that tracks and reports resource consumption per tenant (account) for cost recovery or billing purposes. The system must aggregate existing `TokenUsage` and `ContainerMetric` data, support multiple billing models, and provide an API for external billing system integration.

### Requirements

1. Track resource consumption (tokens, runs, compute) by tenant
2. Support billing periods (daily, weekly, monthly)
3. Support multiple billing models (per-token, per-run, per-project, flat rate)
4. Generate invoices with itemized line items
5. Provide a JSON API for external billing system integration
6. Build on existing `TokenUsage` and `ContainerMetric` data without duplication

## Decision

### Data Model

```
┌─────────────┐     ┌────────────────┐     ┌─────────────────┐
│   Account    │────▶│  BillingPlan   │────▶│  BillingPeriod  │
│  (tenant)    │     │                │     │                 │
└─────────────┘     │ billing_model  │     │ starts_at       │
       │            │ period_type    │     │ ends_at         │
       │            │ base_rate      │     │ status          │
       │            │ per_token_rate │     │ total_cost_cents│
       │            │ included_*     │     │ total_tokens    │
       │            └────────────────┘     │ total_runs      │
       │                                   └────────┬────────┘
       │                                            │
       │            ┌────────────────┐     ┌────────▼────────┐
       └───────────▶│ BillingInvoice │────▶│ BillingLineItem │
                    │                │     │                 │
                    │ external_id    │     │ description     │
                    │ status         │     │ line_item_type  │
                    │ total_cents    │     │ quantity        │
                    └────────────────┘     │ total_cents     │
                                           └─────────────────┘
```

**Key tables:**

- **billing_plans** — Defines billing configuration per account: billing model type (per_token, per_run, per_project, flat_rate), rates, included allowances, and period type.
- **billing_periods** — Tracks billing periods with aggregated usage summaries. Status transitions: open → closed → invoiced.
- **billing_invoices** — Generated invoices with totals. Status transitions: draft → issued → paid (or void). Supports `external_id` for integration with external billing systems (e.g., Stripe).
- **billing_line_items** — Itemized charges on an invoice (base rate, token usage, overage, adjustments).

### Billing Models

| Model | Charges Based On | Use Case |
|-------|-----------------|----------|
| `flat_rate` | Fixed base rate per period | Simple unlimited plans |
| `per_token` | Token consumption with included allowance | Usage-based with commitment |
| `per_run` | Agent run count with included allowance | Run-based pricing |
| `per_project` | Active project count with included allowance | Project-based tiers |

### Aggregation Strategy

Usage is aggregated from existing tables at invoice generation time — not streamed into billing tables in real-time. This avoids dual-write complexity and ensures billing data always reflects the source of truth.

```
TokenUsage (via agent_runs.project_id → projects.account_id)
  └─► Billing::AggregateTenantUsage aggregates by account + time range
       └─► Billing::GeneratePeriodSummary snapshots into BillingPeriod
            └─► Billing::CalculateCharges applies plan rates
                 └─► Billing::GenerateInvoice creates invoice + line items
```

The `TokenUsage.billable` scope is reused to avoid double-counting `run_summary` audit records — the same logic used by the existing cost dashboard.

### API Design

All endpoints are under `/api/billing/` and require admin-level account access.

| Endpoint | Description |
|----------|------------|
| `GET /api/billing/usage` | Real-time usage aggregation for a time range |
| `GET /api/billing/plan` | Current active billing plan |
| `GET /api/billing/periods` | List billing periods |
| `GET /api/billing/periods/:id` | Period details with metadata |
| `GET /api/billing/invoices` | List invoices |
| `GET /api/billing/invoices/:id` | Invoice details with line items |

### Authorization

Billing data is restricted to account owners and admins via `BillingPolicy#billing?`. This aligns with the existing RBAC model from RDR-010.

## Alternatives Considered

1. **Real-time event streaming** — Writing billing events as they occur would add dual-write complexity and risk inconsistency with the source `TokenUsage` records. Rejected in favor of on-demand aggregation.

2. **External billing system as primary** — Delegating all billing logic to Stripe or similar. Rejected because Paid needs internal usage tracking regardless, and the billing data model should be system-agnostic.

3. **Extending CostBudget for billing** — CostBudgets serve a different purpose (enforcement/guardrails) and operate at the project level, not tenant level. Billing requires account-level aggregation and invoice generation.

## Consequences

- Account-level usage aggregation queries join through `agent_runs → projects → accounts`. For accounts with many projects and runs, these queries may need optimization (materialized views or periodic snapshots).
- The `external_id` field on invoices enables integration with Stripe, but the webhook/sync layer is not included in this initial design.
- Billing periods are manually triggered (via service calls) rather than auto-generated. A scheduled job to close periods and generate invoices can be added as a follow-up.
