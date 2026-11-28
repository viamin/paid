---
parent: PAID
prefix: RAILS-CONTROL-PLANE
---

# Low-Level Design: Rails Control Plane

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented Rails control-plane foundation described in
> `docs/rdrs/RDR-001-web-framework-selection.md`.

## Purpose

Paid's control plane is a Rails application that owns the authenticated web
surface, tenant-aware request lifecycle, real-time browser updates, and
lightweight background execution that does not need durable workflow semantics.

## Shipped Architecture

The shipped implementation uses Rails controllers, Active Record models, ERB
views, Hotwire/Turbo updates, Action Cable connections, and GoodJob worker
threads. The current view stack is ERB, not Phlex. That is an intentional
deviation from the original illustrative RDR language and matches the current
project guidance.

Request handling establishes tenant context before application code runs and
clears it after the request completes, including failure paths. This keeps the
control plane aligned with the database RLS model.

Development primary and test database connections may take their complete
connection from `DATABASE_URL` when a CI or externally provisioned database
supplies one. Development cable retains its dedicated database connection;
production's explicit primary/cache/cable configurations prevent the generic
`DATABASE_URL` from overriding their configured roles. Development
database connections disable PostgreSQL JIT. Inbox eligibility
queries have large plans that PostgreSQL otherwise compiles for seconds even
when the underlying execution takes milliseconds. The setting is scoped to
development connections so request and background workers use the same plan
behavior without changing production database policy.

That same request lifecycle fail-closes tenant access at the controller layer.
Active accounts proceed normally, suspended accounts stay read-only for
mutating requests, and deactivated accounts lose both HTML and API access with
their session revoked. This is the application-level guardrail that sits in
front of the deeper PostgreSQL RLS isolation.

Authenticated HTTP requests also stamp the encrypted Action Cable cookie used by
`ApplicationCable::Connection`, because websocket requests do not carry the
Devise/Warden middleware state that normal controller requests have.

GoodJob remains the mechanism for lightweight asynchronous work such as cron
sweeps, notifications, cleanup, and health checks. Durable multi-step agent
execution does not run in GoodJob; it is delegated to Temporal.

The dedicated GoodJob worker has a separate liveness contract from its boot
readiness marker.  Its marker remains ready only while the worker can observe a
fresh GoodJob process heartbeat and running schedulers.  The marker records a
fresh worker-health heartbeat and bounded scheduler/queue progress metadata;
an idle worker is healthy, and a long-running owned job is not treated as a
queue-progress failure merely because its execution counter does not change.
Queue eligibility uses GoodJob's queue expressions, pause filters, scheduling,
and ownership scopes for each scheduler pool. Capacity and progress are matched
to that same pool: an idle unrelated pool cannot make occupied or excluded
work look stalled, and another pool's completions cannot hide a stalled pool.
The progress window resets when the pool has no eligible waiting work or no
available thread. When eligible work continuously waits for an available
thread in its pool without a bounded GoodJob dispatch or completion update, or when the GoodJob process heartbeat is stale, the
worker withdraws readiness and requests GoodJob's graceful shutdown.  This
preserves active execution ownership during the configured drain window; a
replacement must let GoodJob's normal ownership and expiry mechanisms decide
when work is eligible again.  The health monitor never marks readiness healthy
or renews audit allowances to manufacture progress, and it records only counts,
timestamps, and process identity rather than job payloads or credentials.

The devcontainer runs GoodJob in the dedicated `bin/jobs` process so bounded
maintenance, metrics, and dashboard work cannot consume Puma request slots
needed by isolated-container credential bootstrap or health checks. Its web
process defaults to five Puma threads with a pool of ten database connections;
after the bounded three-request control-plane workload, two default request
slots remain for the broker and health probes. `bin/dev-web` applies external
job execution and the default thread capacity at every startup, so ordinary
updates of an existing container cannot accidentally run both job pools. Explicit
operator thread-budget overrides remain authoritative. A small shell wrapper restarts the web process after
exit 137, which commonly indicates a memory kill. It backs off and stops after
three restarts within five minutes; other exits surface to Overmind normally.
The existing development supervisor records lightweight process RSS and host
memory samples before a crash, so a killed process's memory growth can be
distinguished from pressure elsewhere in the workspace.
The supervisor checks tmux panes only on sockets with live sessions. An old
tmux server can answer `tmux ls` successfully while listing no sessions; after
one minute, startup stops that server and removes its socket. Health checks
ignore empty servers so they cannot mark a newer Overmind session unhealthy.
Startup holds a workspace-scoped lock while it cleans sockets and launches
Overmind, so a concurrent startup cannot replace a checked empty socket before
it is stopped. A concurrent same-workspace startup refuses promptly rather
than waiting for the active development session to exit. New sockets remain
untouched while their first session starts; a socket without panes does not
identify a worktree, so it does not block another worktree with the same name.
When Overmind's control socket is missing but a tmux session remains, startup
refuses to launch duplicate services and directs the developer to inspect the
old session. A full `bin/dev-update` identifies same-workspace panes through
the app-scoped Overmind tmux socket and pane path, then stops only those
sessions before setup and replacement startup. It leaves other worktrees and
unrelated tmux servers alone. A socket for which tmux explicitly reports that
no server is running, or whose path disappears before inspection, is not a live
session and does not prevent setup or
replacement startup. Unknown inspection errors remain blocking. If a live
session cannot be inspected or stopped,
the updater stops before setup and reports the socket/session identity with a
diagnostic snapshot.

The development web process also exposes PgHero at `/pghero` without
authentication by default. PgHero is a development-only Rails engine that
inspects the same PostgreSQL connection configured for Paid through
`DATABASE_URL`; it does not add a service, a database, or a production route.
PgHero is mounted only when Rails runs in development, so the system-test
environment does not load its dashboard route while retaining the development
dependencies that Paid's eagerly loaded test application requires.
`bin/dev` binds the native development server to loopback. Docker Compose
publishes its web port to the host loopback interface while the server listens
on the container network, so the dashboard remains reachable from the host
without being exposed through Tailscale or other network interfaces. A developer
can optionally set `PGHERO_PASSWORD` to require HTTP Basic authentication. The
`.devcontainer` VS Code environment is a
different case: it already forwards its web port on all host interfaces so a
developer can reach the whole app over Tailscale, predating PgHero, so it sets
`PAID_WEB_BIND_ADDRESS=0.0.0.0` rather than relying on the native loopback
default. PgHero rides along with the rest of the app there and is reachable by
anyone who can access the forwarded development web port, including restricted
agent containers that can reach the Compose proxy.
The unauthenticated dashboard is read-only: Paid rejects its non-GET requests
and hides PgHero's query termination and Explain controls. This keeps query
stats visible without letting a network caller reset stats or interrupt work.
PgHero normalizes query text before display to hide literal values in live
queries and query stats.
Development PostgreSQL preloads `pg_stat_statements`, and the development
primary database installs its extension so PgHero can show current query stats
and slow queries. This applies to both Docker Compose and the VS Code
devcontainer without changing production PostgreSQL configuration. `bin/setup` installs the extension on
existing Compose development databases when query stats are enabled in the
container environment. The development dashboard flags queries
averaging at least 100 ms over five calls so low-volume performance problems
are visible locally.

Resource profile refreshes read only the run fields needed for memory samples
and load metric limits for the current bounded database batch. The five
fallback profile levels execute as a
continuation chain, one level per GoodJob perform, so a refresh does not retain
all five levels' working sets in one job.

Development code reload must complete even when an Action Cable broadcast is
pending. Solid Cable 4.1 batches broadcasts through a Rails executor worker, so
its shutdown is deferred only while the Rails unload lock is held. Outside code
reload, shutdown remains synchronous. Broadcasts must survive shutdown and work
afterward.

## Development database investigation history

Development query diagnostics retain samples in the existing primary database
using PgHero's query, query-statistics, and space-statistics tables. The tables
are installed through normal Rails migrations; collection runs only in
development through GoodJob. Jobs check the environment before referencing the
development-only PgHero gem. These database-wide diagnostic records are system
infrastructure rather than tenant-owned records. The dashboard retains its
existing read-only routes and query normalization. Stored query text is also
normalized before persistence, including utility statements that PostgreSQL may
report with literal values. PostgreSQL scanner token boundaries remove SQL
comments and replace residual literals after normalization, without treating
quoted identifiers or comment-like text inside string literals as SQL comments.

A scheduled job captures query statistics once per minute, with overlapping
captures and cleanup serialized through the same database advisory lock across
web processes. PgHero 4.1 captures the 100 queries
with the highest combined planning and execution time and resets the primary database's current
query counters. Historical samples describe capture intervals; current counters
describe work since the latest capture. Committed samples survive database
recovery; the unsampled interval and interrupted queries can still be lost.
Capture resets and inserts are not atomic in PgHero, so failure after a
successful reset can lose an interval. Failed capture surfaces as a failed job,
not as a successful empty sample, without an immediate unbounded retry loop
during database recovery. All three history jobs use ApplicationJob's 30-second
perform ceiling so stalled diagnostics cannot occupy a worker indefinitely.
Setup provisions an administrator-owned, no-argument
reset helper restricted to the connected development database. The helper uses
a fixed safe search path, revokes public execution, and grants execution only
to the configured non-superuser application role. Reprovisioning restores
administrator ownership and revokes prior helper execution grants before
granting the configured role access. Collection uses that helper;
the application role receives neither superuser authority nor general access to
PostgreSQL's statistics-reset function.

A daily job records table and index sizes and removes samples older than
14 days from both statistics tables. Query-text records without retained samples
are also removed so distinct query text cannot grow without bound. Retention
applies only to diagnostic history. Missing tables before migration do not
prevent application boot; capture failures remain visible in GoodJob.

Setup resolves its environment from `RAILS_ENV`, then `RACK_ENV`, then the
development default before running any diagnostic administrator provisioning.
Development PostgreSQL enables `pg_stat_statements.track_planning` alongside
execution statistics. Both Compose configurations carry the setting, and setup
applies it to an existing supported local development server through the
query-statistics provisioning boundary. Planning measurements add overhead,
particularly when concurrent connections plan the same query. Operators can
disable planning tracking without disabling query or space history. PgHero 4.1
includes planning time in displayed and persisted query totals but does not
display or persist planning counters separately; SQL against
`pg_stat_statements` exposes them until the next capture reset or recovery.
Neither PgHero history nor planning counters measure peak process memory or
establish which process caused an out-of-memory kill.

### History decisions and alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| Store history in the primary database and collect through GoodJob | Uses the existing development stack and preserves committed samples across PostgreSQL recovery. | A separate monitoring database and scheduler add operating cost without recovering the unsampled interval. |
| Use PgHero's supported interval capture | Supplies the dashboard's native query history with bounded capture size. | Custom cumulative snapshots avoid resets but require new counter-delta and reset-detection behavior. |
| Retain 14 days and prune unused query text | Provides recent incident context with bounded historical duration. | Unlimited retention accumulates diagnostic data indefinitely. |
| Enable development planning measurements with an operator opt-out | Makes expensive planning observable without changing production policy. | Execution-only measurement leaves nested-query planning costs unmeasured. |
| Run devcontainer GoodJob externally with a default of five web threads | Keeps the credential broker and health checks serviceable during bounded control-plane work while retaining finite worker concurrency and the existing ten-connection per-process pool. | In-process GoodJob shares the three-thread Puma process and can delay the broker behind control-plane work. |

## Development PgHero Overview finding issues

A development-only scanner turns the warnings PgHero's Overview (including its
extended view) would show a developer into tracked GitHub issues in the
tenant's self repository, so database problems do not depend on someone
happening to open `/pghero`. The scanner reads PgHero's Ruby methods — the
same methods the Overview controller calls with the same thresholds — and
never scrapes the dashboard HTML. Collection, persistence state, and issue
filing run through one path shared by the scheduled GoodJob job and the
manual `bin/rails development:pg_hero_overview_scan` invocation. The job,
schedule, and collector are development-only: the cron entry lives in the
same development-gated block as the history capture jobs, and the job
returns early outside development before referencing PgHero.

### Finding inventory and policy

Every Overview warning category is inventoried. Each becomes either an
actionable finding (an issue is filed), a persistence-gated finding (an
issue is filed only after the finding is observed on consecutive scans), or
an informational exclusion with a recorded reason.

| Overview category | Policy | Stable identity |
| --- | --- | --- |
| Slow queries | Actionable. PgHero's own window aggregation (3-hour history plus current counters, average ≥ `slow_query_ms` over ≥ `slow_query_calls` calls) is the minimum-impact gate that keeps cumulative `pg_stat_statements` totals and per-minute capture resets from flooding: a query must repeatedly be slow inside the window, not once since server start. | database + `slow_query` + query hash |
| Suggested indexes | Actionable. Overview thresholds (average ≥ 20 ms, ≥ 50 calls) are the minimum impact. Framed as an investigation lead, never a schema-change instruction. | database + `suggested_index` + table + columns |
| Invalid indexes | Actionable. A structurally broken index never self-heals. | database + `invalid_index` + schema + index name |
| Invalid constraints | Actionable. | database + `invalid_constraint` + schema + constraint name |
| Duplicate indexes | Actionable. | database + `duplicate_index` + unneeded index name |
| Unused indexes (extended view) | Actionable at ≥ `unused_index_bytes`. | database + `unused_index` + schema + index name |
| Sequence danger (≥ 90% of max) | Actionable. | database + `sequence_danger` + table + column |
| Unreadable sequences | Actionable as an investigation lead (capacity monitoring is blind there). | database + `unreadable_sequence` + table + column |
| Transaction ID danger | Actionable at the Overview threshold. | database + `xid_danger` + schema + table |
| Inactive replication slots | Actionable where present (retained WAL). | database + `replication_slot` + slot name |
| Long-running queries | Persistence-gated (2 consecutive scans): a single ≥ 60 s query is usually deliberate maintenance or a one-off; only a recurring one is tracked. Autovacuum workers are excluded as expected maintenance. | database + `long_running_query` + literal-filtered query fingerprint |
| Total connections at/above threshold | Persistence-gated (2 consecutive scans): transient dev bursts are normal. | database + `connection_pressure` |
| Idle-in-transaction connections (≥ 100) | Persistence-gated (2 consecutive scans). | database + `idle_in_transaction` |
| Cache hit rate below threshold (extended view) | Persistence-gated (2 consecutive scans): the underlying counters are cumulative since reset, so one reading can just reflect a cold start. A nil rate (no reads yet) is skipped as insufficient data. | database + `cache_hit_rate` + table/index kind |
| Query stats unavailable | Actionable coverage finding (the fix — installing the extension — is real work) and marks the scan incomplete rather than clean. | database + `query_stats_unavailable` |
| Replication lag | Informational exclusion: the development database is a primary, so the Overview's replica-only lag check does not apply. | — |
| Autovacuum workers shown with long-running queries | Informational exclusion: expected maintenance activity. | — |

### Repair assessment and ownership

Stable finding identities track observations independently of work ownership.
A project-scoped repair owns a selected set of observations and one canonical
issue or pull request. Several findings may share a repair, including different
finding types resolved by the same action. An observation alone does not publish
work. Existing issue links are imported without creating replacement issues;
trusted PR closing references preserve explicit shared ownership. Consolidating
existing repairs retains each source's distinct instructions and rationale under
the canonical owner. Repeated imports do not append the same source again.

Before publishing new work, the scanner supplies current findings, persisted
repair coverage, and trusted open GitHub work to a bounded assessment through
`Llm::Request` and `agent_harness`. The assessment proposes repairs, their exact
finding keys, rationale, and existing owners, or defers findings with a reason.
When full evidence exceeds the input budget, AI reads compact indexes of every
pending observation and open work item, then selects a repair scope and plausible
owners for detailed assessment. Unselected observations receive a reasoned
deferral for later scans. Each inference input stays within 90 KB before prompt
framing; arbitrary inventory tails are never silently discarded. Imported investigations retain their authored text;
new shared membership appends aggregate evidence instead of replacing it.
Code validates the complete partition of unassigned actionable findings, known
same-project owners, database boundaries, and bounded input/output. It makes no
semantic grouping decisions from table names, category strings, or title matches.
Assessment, trust, lookup, or validation failure defers publication and surfaces
incomplete coverage; it never falls back to one issue per finding.

Successful detailed assessments persist their time, evidence fingerprint and
reason on each assessed observation. A selection-only deferral is pending work,
not a completed assessment. Bounded selection must include the least recently
assessed pending observation, with never-assessed observations first, while AI
may add related findings and plausible owners from the complete indexes. This
rotates the assessment frontier without grouping findings by naming rules.
Failures and previews do not advance assessment history.

Publication requires an explicit affirmative readiness decision with supporting
evidence and no missing prerequisites. Conditional proposals remain deferred
with their missing evidence. Duplicate-index assessment includes the actual catalog definitions, validity and
uniqueness flags for both the candidate and retained covering index. Zero
recorded index scans alone do not establish a safe removal: representative workload, catalog redundancy or measured query
behavior must support the repair. Retaining a needed covering or search index
is part of assessing the repair, not a reason to delete it to clear a warning.

The publisher renders all members of a managed repair together. A finding loses
observation continuity when absent, but can be resolved only when its category
was collected. The repair closes only after every member is resolved. A missing
category retains its last evidence and keeps the owner open. Reused human issues
and PRs remain externally managed; the scanner never rewrites or closes them.
A `pghero-repair-covers` marker declares coverage without transferring lifecycle
ownership; scanner-origin finding or repair markers establish managed work.
Explicitly superseded legacy issue links remain historical aliases and are not
reopened while a canonical repair owns the finding. Recurrence reuses that owner.

GitHub bodies carry repair and finding markers for recovery after local state
loss or a remote-write/local-rollback failure. Recovery includes closed issues,
repairs unlinked observation rows, and preserves an existing link before choosing
an open then oldest marked owner. Unpublished repairs retained by a capped scan
recover ambiguous remote publication by their stable repair marker. Newly declared
coverage joins the existing owner rather than creating another repair with the
same issue number. Per-run publication caps apply to new repair
issues, not to the number of observations assessed.

`development:pg_hero_overview_preview` uses the scheduled path with GitHub writes
suppressed and scan-state changes rolled back. It reports proposed publication,
existing ownership, deferrals, and incomplete assessment without applying repairs.
Normal development jobs use the repair-aware path after local schema migration.

### Coverage semantics

A scan is complete only when every category could be collected and repair
assessment succeeded. Collection
statement timeouts (the same LockWaitTimeout/QueryCanceled cases the
Overview rescues), unavailable query stats, and GitHub lookup or write
failures each yield a failed or explicitly incomplete scan — never an
apparent all-clear — and categories that could not be observed are excluded
from disappearance decisions so a timed-out catalog read cannot close a
still-open issue. GitHub work is read before publishing; a lookup failure
aborts before GitHub writes. Writes can succeed before their response or local
transaction fails, so retries recover marked remote work before publishing.
Database errors propagate so GoodJob records the failure.

### Scheduling and concurrency

The scan runs hourly at a staggered minute, only in development, on the
maintenance queue. GoodJob concurrency control (total limit 1) prevents
concurrent scheduled performs. The shared scan entry point additionally holds
the target project's database row lock across collection, GitHub lookup, and
issue creation, so manual `perform_now` invocation and scheduled execution
cannot race to file the same finding. The state rows are also updated
transactionally per finding so a retried scan after partial filing resumes from
the issues it already created instead of duplicating them.

### Decisions and alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| One work owner per assessed repair | A repair may resolve several observations; separate persisted membership preserves each observation and prevents premature closure. | Publishing per observation creates overlapping work and repeated CI; grouping by table alone does not establish shared repair coverage. |
| Persist scan state in the primary database | Persistence gating and recurrence need observation history that survives process restarts; the table is system infrastructure like the PgHero history tables. | Rails.cache avoids a migration but loses state on cache clears, breaking persistence gating. |
| Trust PgHero's windowed query stats for slow-query gating | The 3-hour aggregated window with the calls threshold already absorbs counter resets and cumulative totals. | Custom delta tracking duplicates PgHero's combining logic. |
| Cap new issues per run and defer the rest | Bounds GitHub write volume per scan while the next scan retries deferred findings from persisted state. | Filing everything in one run can burst the API and the Inbox. |

## Deferred Work

The RDR's earlier Phlex preference remains deferred. Any future view-layer
migration should update this segment and the representative ERB evidence rather
than assuming component-layer adoption already happened.
