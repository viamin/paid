---
parent: PAID
prefix: DASHBOARD-LIVE-STATS
---

# Dashboard live statistics

The account dashboard header reports running runs, unclaimed queued runs,
completed and failed runs since local midnight, and active create-PR runs.
These are informational counters and do not authorize queue admission.

`Dashboard::LiveStats` uses one aggregate over nonsynthetic runs belonging to
projects in the requested account. Its input includes running and queued runs
regardless of age, plus runs completed since local midnight. Other historical
rows cannot contribute to any counter and are excluded before aggregation.
The existing counter predicates remain authoritative, including failure status
membership and claimed-queue treatment for active create-PR counts.

The result stays in the account-keyed Rails cache for 20 seconds. Tenant RLS
and explicit account/project filtering remain in effect; no run is mutated.

Tests exercise the public service, verify actual aggregate input rows with
PostgreSQL EXPLAIN, and preserve count, cache and isolation behavior.
