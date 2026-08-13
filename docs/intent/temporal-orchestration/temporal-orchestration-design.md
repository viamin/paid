---
parent: PAID
prefix: TEMPORAL-ORCHESTRATION
---

# Low-Level Design: Temporal Orchestration

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented orchestration foundation described in
> `docs/rdrs/RDR-002-workflow-orchestration.md`.

## Purpose

Paid uses Temporal for durable, replay-safe orchestration of long-running agent
and automation workflows that must survive process restarts, cancellations, and
retries.

## Shipped Architecture

The shipped implementation uses the official `temporalio` Ruby SDK. Client
connections are created lazily from Rails so boot time does not eagerly load the
native Temporal client stack.

Workflow and activity code lives under `app/temporal/workflows` and
`app/temporal/activities`. This is the intentional shipped path layout,
replacing the earlier illustrative `app/workflows` and `app/activities`
examples in the RDR.

Paid runs separate Temporal task queues for polling and agent workloads. Poll
work is isolated from long-running agent execution so time-sensitive repository
polling does not compete with broader execution throughput.

GoodJob still exists beside Temporal, but only for lightweight Rails job work.
Temporal owns the durable multi-step orchestration paths.

## Worker Capacity Model

Temporal worker configuration derives the minimum Active Record pool size from
the selected worker mode and activity-slot counts. Regular activities can
consume an additional database connection through heartbeat helper threads, so
pool sizing must account for both activity slots and heartbeat threads.

## Deferred Work

Operational choices such as deployment topology changes or Temporal Cloud
adoption are outside this brownfield backfill. This segment documents the
currently shipped self-managed Ruby worker model.
