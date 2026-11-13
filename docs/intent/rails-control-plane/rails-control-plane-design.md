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

Development runs GoodJob in the web process to avoid the memory overhead of an
additional Rails process. A small shell wrapper restarts the web process after
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
unrelated tmux servers alone. If the session cannot be inspected or stopped,
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
devcontainer; it does not enable PgHero's historical query capture or change
production PostgreSQL configuration. `bin/setup` installs the extension on
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

## Deferred Work

The RDR's earlier Phlex preference remains deferred. Any future view-layer
migration should update this segment and the representative ERB evidence rather
than assuming component-layer adoption already happened.
