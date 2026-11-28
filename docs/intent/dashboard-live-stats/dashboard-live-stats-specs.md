# Dashboard live statistics specifications

- [x] **DASHBOARD-LIVE-STATS-001** — The live counters SHALL preserve running,
  unclaimed-queued, completed-today, failed-today and active create-PR counts,
  including old running/queued rows and the existing completion-time predicates.
  *Code:* `Dashboard::LiveStats`.
  *Tests:* `spec/services/dashboard/live_stats_spec.rb`,
  `spec/services/dashboard/live_stats_input_scope_spec.rb`.

- [x] **DASHBOARD-LIVE-STATS-002** — On a cache miss, the aggregate SHALL exclude
  historical terminal rows before counter evaluation without adding a query.
  *Code:* `Dashboard::LiveStats`.
  *Tests:* `spec/services/dashboard/live_stats_input_scope_spec.rb`.

- [x] **DASHBOARD-LIVE-STATS-003** — Counts SHALL remain account-isolated,
  exclude synthetic operational runs and retain the account-keyed 20-second
  cache contract without mutating runs or queue authority.
  *Code:* `Dashboard::LiveStats`.
  *Tests:* `spec/services/dashboard/live_stats_spec.rb`.
