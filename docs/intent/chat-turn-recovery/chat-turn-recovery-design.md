---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

## Purpose

A chat transcript is not a turn lifecycle. A persisted user message plus tool
rows can otherwise be left without either a terminal assistant response or a
durable explanation. This component records one `ChatTurn` per user message,
detects inactive unfinished turns, and adds a visible transcript notice.

## Lifecycle and detection

Turns move through `pending`, `streaming`, `completed`, `failed`, `stalled`,
and `abandoned`. A durable message write refreshes `last_activity_at`;
completion and classified provider failures are terminal. The maintenance sweep
marks only `pending` or `streaming` turns inactive for the configured timeout
as `stalled`. Pending tool confirmations and a declared long-running deadline
are exclusions, so waiting for a user or a known operation is not misreported.

The detector locks each candidate before transition, making repeat sweeps
idempotent. It preserves all transcript rows and writes a system notice rather
than manufacturing an assistant answer.

## Recovery boundary

This first slice intentionally does not automatically replay a stalled turn.
There is no provider-independent checkpoint contract proving that replay cannot
repeat a write tool. Users can inspect preserved tool cards before explicitly
continuing; automatic recovery remains opt-in for a future tool contract that
supplies an idempotency key and a durable checkpoint.

## Observability

`ChatTurn` exposes lifecycle status, failure classification, timestamps, and
recovery count as queryable data. Structured stall logs carry the turn and
session identifiers. Subsequent recovery work must record every attempt and
deduplication decision on this row under its lock.
