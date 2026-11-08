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
production discards the generic `DATABASE_URL` before Active Record resolves
its explicit primary/cache/cable configuration. Development
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
