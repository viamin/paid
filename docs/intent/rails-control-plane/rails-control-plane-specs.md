# EARS Specs: Rails Control Plane

> Testable claims for the implemented Rails control plane. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r RAILS-CONTROL-PLANE-001`).

## Request and Realtime Lifecycle

- [x] **RAILS-CONTROL-PLANE-010** — When Rails connects to the development
  PostgreSQL database, the connection SHALL disable JIT so interactive
  requests do not pay compilation cost for short eligibility queries; the
  production connection SHALL retain its default PostgreSQL JIT policy.
  *Tests:* `spec/config/active_record/database_configurations_spec.rb`.
  *Code:* `config/database.yml`.

- [x] **RAILS-CONTROL-PLANE-013** — When a non-production Rails boot provides
  `DATABASE_URL`, the development primary and test database configurations
  SHALL use that complete connection URL; development cable SHALL retain its
  dedicated database configuration without a generic URL mapping. Production
  SHALL retain `DATABASE_URL` while resolving its explicit primary/cache/cable
  configuration so the configured roles remain authoritative.
  *Tests:* `spec/paid/database_yml_erb_spec.rb`.
  *Code:* `config/database.yml`.

- [x] **RAILS-CONTROL-PLANE-009** — When Action Cable shuts down during a
  development code reload with a broadcast pending, the control plane SHALL
  complete shutdown without deadlocking, preserve the broadcast, and support
  broadcasts after restart.
  *Tests:* `spec/integration/action_cable/subscription_adapter/solid_cable_reload_spec.rb`.
  *Code:* `Gemfile`, `Gemfile.lock`, `lib/solid_cable/reload_safe_shutdown.rb`.

- [x] **RAILS-CONTROL-PLANE-001** — When an authenticated Rails request runs,
  the control plane SHALL apply tenant context for the current user's account
  before application code executes and SHALL clear tenant context again after
  the request completes, including when the request raises.
  *Tests:* `spec/controllers/application_controller_spec.rb`.
  *Code:* `ApplicationController#with_current_attributes`.

- [x] **RAILS-CONTROL-PLANE-002** — When an authenticated Rails request reaches
  the control plane, the system SHALL stamp an encrypted cable-auth cookie and
  Action Cable connections SHALL accept only subscribers that can be resolved
  from Warden or that encrypted cookie.
  *Tests:* `spec/channels/application_cable/connection_spec.rb`.
  *Code:* `ApplicationController#stamp_cable_auth_cookie`, `ApplicationCable::Connection`.

- [x] **RAILS-CONTROL-PLANE-006** — When an authenticated request belongs to a
  suspended or deactivated account, the control plane SHALL fail closed at the
  controller layer by allowing suspended accounts read-only access, rejecting
  suspended write attempts, and revoking deactivated account access across
  HTML, JSON, and SSE request paths.
  *Tests:* `spec/requests/tenant_enforcement_spec.rb`.
  *Code:* `TenantEnforcement`, `ApplicationController`.

## Background Work

- [x] **RAILS-CONTROL-PLANE-011** — When a resource profile refresh samples
  finished agent runs, it SHALL read only fields needed for the memory sample
  and use bounded database batches for every profile level, including metric
  limits for only the runs in the current batch.
  *Tests:* `spec/services/agent_run_resource_profiles/refresh_for_run_spec.rb`.
  *Code:* `AgentRunResourceProfiles::RefreshForRun#source_runs_for`,
  `AgentRunResourceProfiles::RefreshForRun#summarize_samples`.

- [x] **RAILS-CONTROL-PLANE-012** — When a finished run triggers a resource
  profile refresh, each GoodJob perform SHALL calculate one fallback level and
  enqueue the next level only after success, until all five levels are updated.
  *Tests:* `spec/jobs/agent_run_resource_profile_refresh_job_spec.rb`,
  `spec/services/agent_run_resource_profiles/refresh_for_run_spec.rb`.
  *Code:* `AgentRunResourceProfileRefreshJob`,
  `AgentRunResourceProfiles::RefreshForRun`.

- [x] **RAILS-CONTROL-PLANE-003** — The control plane SHALL use GoodJob as its
  lightweight Rails background executor with `async_server` as the default
  execution mode and a declared cron schedule for recurring maintenance and
  queue-processing work.
  *Tests:* `spec/config/good_job_configuration_spec.rb`.
  *Code:* `Paid::GoodJobConfig`, `config/initializers/good_job.rb`.

- [x] **RAILS-CONTROL-PLANE-024** — When the devcontainer serves isolated
  container credential bootstrap under bounded concurrent control-plane work,
  it SHALL run GoodJob in the existing external worker process and configure
  a default of five Puma request threads at web startup without requiring a
  devcontainer rebuild, honoring explicit thread-budget overrides, so two
  request slots remain at the default after three concurrent
  control-plane requests; credential selection, tenant identity, expiry, and
  finite client deadlines SHALL remain unchanged.
  *Tests:* `spec/lib/dev_script_spec.rb`.
  *Code:* `.devcontainer/devcontainer.json`, `Procfile.dev`, `bin/dev-web`, `bin/jobs`,
  `config/puma.rb`.

- [x] **RAILS-CONTROL-PLANE-030** — When the dedicated GoodJob worker is
  running, its readiness metadata SHALL distinguish boot readiness from a
  fresh GoodJob process heartbeat, scheduler availability, and bounded queue
  progress. An idle worker and a worker with only legitimately occupied
  scheduler threads SHALL remain healthy. If the worker loses process-record
  visibility, its heartbeat becomes stale, or runnable work waits beyond the
  configured progress window while a thread in that work's eligible scheduler
  pool is available, the worker
  SHALL withdraw readiness and request the existing graceful GoodJob shutdown;
  it SHALL preserve active job ownership and SHALL not log job payloads or
  credentials.
  Queue eligibility SHALL honor GoodJob queue expressions, pauses, scheduling,
  and retained ownership. Progress in an unrelated pool SHALL not reset a
  stalled pool's window, and idle or occupied intervals SHALL not consume the
  next continuously waiting window. A GoodJob dispatch timestamp SHALL reset
  the eligible pool's progress window before that execution completes.
  *Tests:* `spec/lib/paid/good_job_worker_spec.rb`,
  `spec/lib/paid/good_job_worker/health_snapshot_spec.rb`,
  `spec/lib/paid/worker_readiness_spec.rb`.
  *Code:* `lib/paid/good_job_worker.rb`, `lib/paid/worker_readiness.rb`,
  `lib/paid/good_job_worker/health_snapshot.rb`, `bin/jobs`.

- [x] **RAILS-CONTROL-PLANE-014** — When the development web process exits 137,
  its wrapper SHALL restart it with bounded backoff without stopping the
  Temporal workers. Other exit codes and repeated exit 137 SHALL surface as
  failures.
  *Tests:* `spec/lib/dev_script_spec.rb`.
  *Code:* `Procfile.dev`, `bin/dev-web`.

- [x] **RAILS-CONTROL-PLANE-015** — While the development supervisor monitors
  Overmind, it SHALL periodically record Puma RSS, Temporal worker RSS, host
  available memory, workspace cgroup usage and limit, and the OOM kill counter
  without starting another long-running process.
  *Tests:* `spec/lib/dev_script_spec.rb`.
  *Code:* `bin/lib/dev_supervisor.sh`.

- [x] **RAILS-CONTROL-PLANE-016** — When a tmux socket is at least one minute old
  and its server has no sessions, development startup SHALL stop that server
  and remove its socket. It SHALL preserve newer sockets while their first
session may be starting. Startup SHALL serialize same-workspace socket cleanup
with Overmind launch so an inspected socket cannot be replaced before it is
stopped. Supervisor health checks SHALL ignore empty servers rather than
restart a healthy Overmind session, while still detecting dead panes and
failures when no tmux socket responds.
  *Tests:* `spec/lib/dev_script_spec.rb`.
  *Code:* `bin/lib/dev_supervisor.sh`.

- [x] **RAILS-CONTROL-PLANE-017** — When the Overmind control socket is absent
  but an Overmind tmux session exists for this workspace, or another
  same-workspace startup holds the cleanup-and-launch lock,
  development startup SHALL promptly refuse to launch duplicate services and
  explain how to inspect the existing session.
  *Tests:* `spec/lib/dev_script_spec.rb`.
  *Code:* `bin/dev`, `bin/lib/dev_supervisor.sh`.

- [x] **RAILS-CONTROL-PLANE-019** — When a full `bin/dev-update` finds no
  Overmind control socket but finds a live Overmind tmux pane rooted at its
  workspace, it SHALL stop only that socket/session before setup and replacement
  startup. It SHALL not stop another worktree's session or act when no matching
  session exists. If tmux explicitly reports no server running at a socket
  or that its path no longer exists,
  it SHALL continue setup and replacement startup without attempting to stop
  a session at that socket. If inspection otherwise fails or stopping fails, it SHALL fail before setup
  with the socket/session identity and a diagnostic snapshot.
  *Tests:* `spec/lib/dev_update_spec.rb`.
  *Code:* `bin/dev-update`, `bin/lib/dev_supervisor.sh`.

- [x] **RAILS-CONTROL-PLANE-018** — When a developer starts Paid with
  `bin/dev`, the development web process SHALL expose PgHero at `/pghero` without
  authentication by default for requests to the PostgreSQL
  database configured through `DATABASE_URL`. PgHero's gem and route SHALL be
  absent from non-development environments, and the integration SHALL not
  require another service or database. The system-test environment SHALL NOT
  mount the PgHero route. Native development SHALL bind the web
  server to loopback; Docker Compose SHALL publish the web port only to host
  loopback while allowing the published request to reach PgHero. Requests from
  Tailscale reaching `docker-compose.yml`'s published port SHALL NOT load the
  PgHero dashboard. A configured `PGHERO_PASSWORD` SHALL enable HTTP Basic
  authentication. The
  `.devcontainer` VS Code environment already forwards its web port for direct
  Tailscale reachability of the whole app, predating PgHero; that forwarding
  SHALL continue, so PgHero SHALL be accessible without credentials to anyone
  who can reach that forwarded development web port, including restricted agent
  containers that can reach the Compose proxy. PgHero SHALL reject non-GET
  requests, hide query termination and Explain controls, and normalize displayed
  query text to filter literal values. Development PostgreSQL SHALL
  preload `pg_stat_statements`, and a newly initialized development primary
  database SHALL install the extension so PgHero shows current query stats and
  slow queries without requiring historical query capture. `bin/setup` SHALL
  also install the extension on existing Compose development databases. The development
  dashboard SHALL flag queries averaging at least 100 ms after five calls.
  *Tests:* `spec/config/pg_hero_development_integration_spec.rb`,
  `spec/requests/pghero_development_spec.rb`, `spec/lib/setup_script_spec.rb`.
  *Code:* `Gemfile`, `config/routes.rb`, `config/routes/pghero_development_routes.rb`,
  `config/pghero.yml`, `bin/dev-web`, `bin/setup`, `docker-compose.yml`,
  `.devcontainer/compose.yaml`, `docker/postgres/init-multiple-dbs.sh`.

- [x] **RAILS-CONTROL-PLANE-020** — While Rails runs in development with
  PgHero history tables migrated, GoodJob SHALL schedule query-statistics capture
  every minute for the configured primary database and SHALL prevent concurrent
  captures and cleanup across application processes using the same database
  advisory lock. Each capture SHALL use PgHero's
  supported top-100-by-combined-planning-and-execution-time interval capture, resetting current
  counters for that database and persisting normalized query text, call counts,
  combined planning/execution totals, and capture time in the existing primary database. Previously
  committed samples SHALL remain available after database recovery. Stored query
  text SHALL filter literal values, including those in utility statements, and
  remove SQL comments without corrupting multibyte query text.
  Non-development environments SHALL NOT schedule or execute PgHero collection
  or require its development-only gem at job execution. Development setup SHALL
  provision an administrator-owned, no-argument reset helper scoped to the
  connected database with a fixed safe search path and public execution revoked.
  Only the configured application role SHALL receive helper execution; that
  role SHALL remain non-superuser without general statistics-reset authority.
  Reprovisioning SHALL restore administrator ownership and revoke former
  application roles' helper execution grants.
  *Tests:* `spec/jobs/pg_hero_capture_query_stats_job_spec.rb`,
  `spec/services/development/pg_hero_history_spec.rb`,
  `spec/config/pg_hero_development_integration_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development database investigation history.

- [x] **RAILS-CONTROL-PLANE-021** — While Rails runs in development,
  GoodJob SHALL schedule daily PgHero table/index size capture and cleanup of
  query and space samples older than 14 days in the configured primary database.
  Cleanup SHALL remove query-text records without retained samples, SHALL NOT
  remove query text referenced by retained samples, and SHALL NOT delete
  application business records. Diagnostic tables SHALL be installed by normal
  Rails migrations and SHALL NOT require another database or service.
  *Tests:* `spec/jobs/pg_hero_capture_space_stats_job_spec.rb`,
  `spec/services/development/pg_hero_history_spec.rb`,
  `spec/jobs/pg_hero_clean_history_job_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development database investigation history.

- [x] **RAILS-CONTROL-PLANE-022** — If development PgHero capture fails
  because its tables are missing, PostgreSQL is recovering, permissions are
  insufficient, or persistence fails, the job SHALL report failure through
  GoodJob rather than a successful empty capture and SHALL NOT retry in an
  immediate unbounded loop. Query capture, space capture, and cleanup jobs SHALL
  use the ApplicationJob perform timeout with a 30-second ceiling. Missing
  history tables SHALL NOT prevent application
  boot. Diagnostics documentation SHALL identify the loss of unsampled or
  interrupted work and the possible loss of an interval between PgHero's
  non-atomic reset and insertion. Background collection SHALL preserve the
  dashboard's read-only HTTP boundary and normalization requirements in
  RAILS-CONTROL-PLANE-018.
  *Tests:* `spec/jobs/pg_hero_capture_query_stats_job_spec.rb`,
  `spec/services/development/pg_hero_history_spec.rb`,
  `spec/requests/pghero_development_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development database investigation history.

- [x] **RAILS-CONTROL-PLANE-023** — When development PostgreSQL query
  diagnostics are provisioned through either supported Compose configuration
  or setup of an existing supported local server, the system SHALL enable
  `pg_stat_statements.track_planning` by default and SHALL provide a documented
  operator opt-out independent of query and space history. Provisioning SHALL
  NOT change production PostgreSQL configuration, including when production
  is selected through `RACK_ENV` without `RAILS_ENV`. Documentation SHALL describe
  planning-tracking overhead, how to inspect planning counters through SQL,
  their reset on query capture or database recovery, and their inclusion in
  PgHero 4.1's combined totals without separate planning counters in its display
  or stored history. Documentation SHALL distinguish these
  diagnostics from peak process memory measurements and OOM attribution.
  *Tests:* `spec/config/pg_hero_development_integration_spec.rb`,
  `spec/lib/setup_script_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development database investigation history.

- [x] **RAILS-CONTROL-PLANE-025** — While Rails runs in development, the
  overview scanner SHALL inventory every addressable finding category the
  installed PgHero Overview renders — slow queries, suggested, duplicate,
  invalid, and unused indexes, invalid constraints, long-running queries,
  connection pressure, idle-in-transaction connections, cache hit rate,
  sequence danger, unreadable sequences, transaction ID danger, inactive
  replication slots, and query-stat availability — by calling PgHero's Ruby
  methods with the Overview's thresholds, and SHALL apply the documented
  policy that classifies each category as actionable, persistence-gated, or
  an informational exclusion with a recorded reason. Non-development
  environments SHALL NOT schedule or execute the scan or require the
  development-only PgHero gem.
  *Tests:* `spec/services/development/pg_hero_overview/collect_spec.rb`,
  `spec/services/development/pg_hero_overview/policy_spec.rb`,
  `spec/jobs/pg_hero_overview_scan_job_spec.rb`,
  `spec/config/pg_hero_development_integration_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development PgHero Overview
  finding issues.

- [x] **RAILS-CONTROL-PLANE-026** — While Rails runs in development,
  GoodJob SHALL schedule the PgHero overview scan hourly on the maintenance
  queue with concurrency limited to one perform, and a manual rake
  invocation SHALL run the same collector, policy, state, and issue-filing
  path as the scheduled job. The shared scan path SHALL serialize each target
  project's collection, GitHub lookup, and issue filing independently of
  GoodJob so `perform_now` and scheduled executions cannot create duplicate
  issues for a finding.
  *Tests:* `spec/config/pg_hero_development_integration_spec.rb`,
  `spec/jobs/pg_hero_overview_scan_job_spec.rb`,
  `spec/services/development/pg_hero_overview/scan_spec.rb`,
  `spec/lib/tasks/development_pghero_rake_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.
  *Design:* `rails-control-plane-design.md`, Development PgHero Overview
  finding issues.

- [x] **RAILS-CONTROL-PLANE-027** — The development overview scanner SHALL
  retain stable project/database/finding identities while publishing one issue
  per assessed repair with explicit member identities and evidence. Recovery
  SHALL adopt marked open or closed work even when observation rows already
  exist, preserve established ownership, and never duplicate an ambiguous write.
  Embedded query text SHALL be literal-filtered and contain no credentials.
  *Tests:* `spec/services/development/pg_hero_overview/issue_filer_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.

- [x] **RAILS-CONTROL-PLANE-028** — When the development PgHero overview
  scan observes a transient category — long-running queries (excluding
  autovacuum workers), connection pressure, idle-in-transaction connections,
  or a below-threshold cache hit rate — it SHALL file an issue only after
  the finding persists across consecutive scans, using persisted observation
  state that survives restarts; cumulative `pg_stat_statements` totals and
  counter resets SHALL be judged through PgHero's windowed aggregation
  rather than raw lifetime counters. The scan SHALL cap new issues per run
  and defer excess findings — without dropping them — to the next scan.
  *Tests:* `spec/services/development/pg_hero_overview/scan_spec.rb`,
  `spec/services/development/pg_hero_overview/issue_filer_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development PgHero Overview
  finding issues.

- [x] **RAILS-CONTROL-PLANE-029** — When a development PgHero overview scan
  cannot observe a category because query stats are unavailable or a
  collection query times out, or when a collector database error, GitHub
  lookup, or GitHub write fails, the scan SHALL surface a failed or
  explicitly incomplete result rather than an apparent all-clear, SHALL NOT
  close issues for categories it could not observe, and SHALL NOT create
  duplicate issues when the GitHub lookup fails.
  *Tests:* `spec/services/development/pg_hero_overview/collect_spec.rb`,
  `spec/services/development/pg_hero_overview/scan_spec.rb`,
  `spec/services/development/pg_hero_overview/issue_filer_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Development PgHero Overview
  finding issues.

- [x] **RAILS-CONTROL-PLANE-007** — When multiple hosts run the GoodJob cron
  scheduler, the system SHALL prevent duplicate scheduled jobs by stamping
  every cron enqueue with a `(cron_key, cron_at)` pair guarded by the unique
  index `index_good_jobs_on_cron_key_and_cron_at_cond`, so a second host firing
  the same tick enqueues nothing.
  *Tests:* `spec/config/good_job_cron_dedup_spec.rb`.
  *Code:* `config/initializers/good_job.rb`, `db/schema.rb`.

## Current View Stack

- [x] **RAILS-CONTROL-PLANE-004** — The control plane SHALL continue to ship
  ERB and Turbo-stream templates as the active view stack until a dedicated
  component-layer migration replaces them.
  *Code:* `app/views/projects/agent_runs/show.html.erb`, `app/views/projects/knowledge_recommendations/update.turbo_stream.erb`.

- [x] **RAILS-CONTROL-PLANE-008** — While the project show page renders its
  header — project name, status badge, action buttons, and external tracker
  link pills — the control plane SHALL keep the page inside the viewport width
  on mobile-size screens: the header containers SHALL wrap, and long project
  names and long external link URLs SHALL break within their flex containers
  rather than widening the document horizontally.
  *Tests:* `spec/system/projects/mobile_header_layout_spec.rb`.
  *Code:* `app/views/projects/show.html.erb` (project header).

- [D] **RAILS-CONTROL-PLANE-005** — When a Phlex migration is approved, the
  control plane SHALL update this segment to replace the ERB-specific claim with
  the new shipped component-layer behavior.

- [x] **RAILS-CONTROL-PLANE-033** — Before creating repair issues, the development
  overview scanner SHALL assess current observations and trusted existing work
  through bounded `Llm::Request`/`agent_harness` inference, validate an explicit
  partition into repair coverage or reasoned deferrals and same-project owners,
  and defer publication on malformed, incomplete, unavailable, or oversized
  evidence. No failure SHALL fall back to per-observation issue creation.
  *Tests:* `spec/services/development/pg_hero_overview/plan_repairs_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.

- [x] **RAILS-CONTROL-PLANE-034** — The scanner SHALL persist repair membership,
  retain one canonical owner across recurrence and trusted supersession, and
  close managed repair issues only when every member is no longer observed in
  successfully collected categories. Shared evidence SHALL be rendered together;
  consolidation SHALL retain each source repair's instructions and rationale
  without appending them again on repeated imports;
  externally managed issues and PRs SHALL NOT be rewritten, reopened, or closed.
  *Tests:* `spec/services/development/pg_hero_overview/issue_filer_sync_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.

- [x] **RAILS-CONTROL-PLANE-035** — Development preview SHALL execute the same
  collection, assessment and planning path with no GitHub writes and no committed
  observation or repair changes, and expose proposed work and incomplete coverage.
  *Tests:* `spec/services/development/pg_hero_overview/scan_spec.rb`,
  `spec/lib/tasks/development_pghero_rake_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.

- [x] **RAILS-CONTROL-PLANE-036** — Successful detailed assessments SHALL persist
  their timestamp, observation fingerprint, disposition and reason. Bounded
  selection SHALL include a never-assessed observation when one exists and the
  least recently assessed pending observation when one exists, while permitting
  AI-selected related findings. Incoming observations SHALL NOT indefinitely
  postpone reassessment of older deferrals. Extra selection metadata SHALL NOT
  affect selected evidence or publication; required fields, known identities and
  response bounds SHALL remain validated. Unselected findings, failed assessments and previews SHALL NOT be
  recorded as completed detailed assessments.
  *Tests:* `spec/services/development/pg_hero_overview/plan_repairs_spec.rb`,
  `spec/services/development/pg_hero_overview/issue_filer_sync_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.

- [x] **RAILS-CONTROL-PLANE-037** — The scanner SHALL publish only proposals with
  affirmative publication readiness, supporting evidence and no missing evidence.
  Conditional proposals SHALL become reasoned deferrals. Assessment SHALL seek
  a safe repair to the underlying concern; zero recorded scans alone SHALL NOT
  establish index-removal readiness. Duplicate-index evidence SHALL include the
  actual candidate and covering index definitions, validity and uniqueness.
  *Tests:* `spec/services/development/pg_hero_overview/plan_repairs_spec.rb`.
  *Design:* `rails-control-plane-design.md`, Repair assessment and ownership.
