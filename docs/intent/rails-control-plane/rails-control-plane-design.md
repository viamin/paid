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

Authenticated HTTP requests also stamp the encrypted Action Cable cookie used by
`ApplicationCable::Connection`, because websocket requests do not carry the
Devise/Warden middleware state that normal controller requests have.

GoodJob remains the mechanism for lightweight asynchronous work such as cron
sweeps, notifications, cleanup, and health checks. Durable multi-step agent
execution does not run in GoodJob; it is delegated to Temporal.

## Deferred Work

The RDR's earlier Phlex preference remains deferred. Any future view-layer
migration should update this segment and the representative ERB evidence rather
than assuming component-layer adoption already happened.
