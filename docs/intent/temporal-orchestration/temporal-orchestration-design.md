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

Agent execution rows move from `queued` to `running` when the queue admits the
Temporal workflow. Provisioning, setup, and preflight consume worker/container
capacity, so operators and capacity controls must see that work as active
rather than as ordinary waiting queue depth.

## Human-input pauses and stale recovery

Stale recovery distinguishes a recoverable execution pause from a deliberate
`create_feature` clarification wait. A paused `create_feature` run carrying a
persisted clarification-round identity is owned by the human-answer flow, not
the stale-run detector: it remains paused regardless of age until that flow or
another explicit supported action requeues it. This run-owned identity remains
authoritative if another write temporarily drifts the issue's `paid_state`.
Other paused runs retain the bounded stale-recovery policy. If another stale
recovery path terminalizes a run carrying that identity while its needs-input
label and stored questions still exist, it restores the issue to `needs_input`
rather than orphaning the answer flow behind `failed`.

Each clarification round has a run-persisted identity embedded in its GitHub
comment. The identity is saved before posting. A retry or restarted workflow
first reconciles issue comments with that identity, then persists the local
needs-input state without reposting if GitHub already accepted the comment.
Answering clears the identity, allowing a later genuinely new round to post.
Run-start processing preserves that human-owned pause: a pending clarification
round blocks `create_pr` before it can overwrite the issue's state. Other run
goals may start, but leave that clarification-owned state unchanged. The
resumed `create_feature` run proceeds only after answer handling clears the
pending label and stored questions.

## Worker Capacity Model

Temporal worker configuration derives the minimum Active Record pool size from
the selected worker mode and activity-slot counts. Regular activities can
consume an additional database connection through heartbeat helper threads, so
pool sizing must account for both activity slots and heartbeat threads.

## Deferred Work

Operational choices such as deployment topology changes or Temporal Cloud
adoption are outside this brownfield backfill. This segment documents the
currently shipped self-managed Ruby worker model.
