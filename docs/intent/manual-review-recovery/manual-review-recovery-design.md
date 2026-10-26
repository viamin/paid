---
parent: PAID
prefix: MANUAL-REVIEW-RECOVERY
---

# Low-Level Design: Manual Review Recovery

## Purpose

Manual review is a parking state with several producer-owned causes. Recovery
must use durable provenance rather than treating every hold as an enhancement
retry. The Inbox therefore classifies a hold from the reopen-review marker,
authoritative unresolved dependency, scanner source, or enhancement-run and
question provenance. Any hold without that evidence remains visible as
unknown and cannot silently start work.

## Recovery contract

An unresolved dependency remains a wait: the Inbox links to the blocking
issue and normal dependency resolution reevaluates readiness. A scanner
recurrence remains an evidence/recovery investigation. A reopen review remains
an intent-validation decision before a supported continuation can be offered.
Only an enhancement-origin hold can use the existing enhancement retry.
Before any recovery action, the shared recovery classifier inspects unfinished
work. An active run takes precedence in the presented action, even when a
dependency or other hold also remains, so it is reconciled visibly and the hold
is retained rather than creating a duplicate run or clearing it.
