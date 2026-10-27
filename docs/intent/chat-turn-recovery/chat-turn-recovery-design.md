---
parent: root
prefix: CHAT-TURN-RECOVERY
---

# Durable Chat Turn Recovery Design

Each asynchronous chat submission owns a durable `ChatTurn`. The record starts
streaming before model work, retains the latest durable activity timestamp, and
is terminal only after an assistant response, a classified failure, or an
explicit abandonment. A maintenance sweep marks an inactive streaming turn
stalled after a configurable timeout.

Pending write-tool confirmation and rate-limited sessions are intentional
pauses, not stalls. A stalled turn persists a transcript notice which names
the unknown outcome and links to any completed side-effecting tool result.
Recovery is deliberately manual in this first slice: the user must explicitly
retry, and the compare-and-swap claim prevents concurrent retries. Automatic
replay remains disabled until a tool exposes an idempotent checkpoint contract.
