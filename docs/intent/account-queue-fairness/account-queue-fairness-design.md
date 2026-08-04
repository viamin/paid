---
parent: PAID
prefix: ACCOUNT-QUEUE
---

# Low-Level Design: Account Queue Fairness

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers account-scoped selection between the current cross-project
> fair-share dequeue policy and the proposed strict-priority alternative.

## Purpose

Paid already ships a fair-share queue posture: scheduler dequeue and dashboard
preview both interleave queued work across projects so a single project backlog
does not monopolize visible capacity. RDR-050 identifies the remaining gap:
some accounts want an explicit strict-priority mode where a P1 run anywhere
beats a P3 run everywhere, even if that reintroduces cross-project starvation.

This segment records both the shipped default behavior and the still-open work
needed to make queue fairness account-configurable rather than hardcoded.

## Shipped Default

Today the queue preview replays the scheduler's fair-share posture instead of
showing a static cluster of one project's backlog. That preserves the product
promise that the upcoming queue approximates dispatch order rather than merely
listing the oldest queued rows.

The current mode is effectively:

- `fair_share` by default and for all accounts
- SQL dequeue ordered by project/user in-flight counts before queue priority
- queue preview interleaved by project to match that dispatch posture
- Temporal fairness still keyed by account, reinforcing cross-project fairness

## Active Gap

RDR-050 turns fairness from a fixed rule into an account decision. The missing
pieces are:

- an account-scoped `queue_fairness_mode` on `tenant_settings`
- a mode-aware scheduler order (`fair_share` vs `strict_priority`)
- display parity so dashboard queue preview and queue-order messaging reflect
  the same mode the scheduler uses
- Temporal fairness-key handling that does not silently reintroduce fair-share
  after a strict-priority SQL claim

## What this is not

- **Not a per-user or per-project preference.** Queue fairness is a property of
  the account's project pool and scheduler.
- **Not a change to the default behavior.** Existing accounts remain on
  fair-share until they opt into a different mode.
- **Not weighted scheduling.** Weighted or deficit-round-robin policies remain
  follow-up work beyond this binary mode switch.
