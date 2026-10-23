---
parent: PAID
prefix: PROJECT-DASHBOARD-METRICS
---

# Low-Level Design: Project Dashboard Metrics

## Purpose

The project page gives every authorized project viewer a concise, inexpensive
summary of delivery metrics. The summary is a daily snapshot rather than a
request-time report, so viewing an active project does not fan out into
historical aggregation queries.

## Design

`ProjectDashboardMetrics::Snapshot` calculates and caches three project-scoped
values: merge lead time for merged pull requests, CI duration from normalized
completed pipeline connector events, and tokens consumed by completed
PR-producing agent runs. Missing source data stays absent; it is never shown
as a zero average.

`ProjectDashboardMetricsSweepJob` refreshes each active project's snapshot
once per day. The project controller reads the cached snapshot after its
ordinary `show?` authorization, and the project view renders the dashboard
above the existing project statistics. This reuses the application's cache and
GoodJob scheduling facilities instead of duplicating the account-level
`Dashboard::Stats` service, whose aggregate scope and agent-duration semantics
do not represent these project metrics.

## Decisions & Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Cache daily snapshots | Calculate on every page view; add a database table | The dashboard is read-heavy and daily freshness is sufficient. Existing cache and GoodJob infrastructure provides bounded storage and scheduled invalidation without a new persistence migration. |
| Use connector pipeline durations for CI | Treat agent-run duration as CI duration | Agent execution is not CI. Only normalized completed pipeline events are an authoritative source for CI duration. |
