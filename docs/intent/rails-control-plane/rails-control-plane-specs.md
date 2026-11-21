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

- [x] **RAILS-CONTROL-PLANE-020** — When the devcontainer serves isolated
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

- [x] **RAILS-CONTROL-PLANE-014** — When the development web process exits 137,
  its wrapper SHALL restart it with bounded backoff without stopping the
  Temporal workers. Other exit codes and repeated exit 137 SHALL surface as
  failures. Development SHALL keep GoodJob in the web process to avoid the
  memory overhead of another Rails boot.
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
