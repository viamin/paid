---
parent: root
prefix: DEPENDENCY-CYCLES
---

# Dependency cycle recovery

## Purpose

Persisted dependency declarations can predate cycle prevention and deadlock open work. Paid detects effective blocking cycles without selecting a declaration to remove, then gives an operator enough provenance to repair it on GitHub.

## Design

`Issues::DependencyCycles::Reconcile` constructs an account-scoped effective graph from open, blocking local dependencies and resolved external references. Parent references and nonblocking states use the same rules as admission. Strongly connected components produce one `DependencyCycleOccurrence` per member set. The record retains a stable identity while its exact cycle path, declaration provenance, project links, and downstream count refresh.

Reconciliation runs after dependency parsing and through the bounded auto-pick periodic sweep. A failed reconciliation is logged as unavailable coverage rather than interpreted as no cycles. An occurrence is resolved only after persisted graph reconciliation no longer finds its member component.

The Inbox derives a recovery lane from active occurrences. The dashboard always shows a cycle warning separately from its capped held-issue detail. Removing an Inbox item remains a user-local presentation action and cannot alter the occurrence or dependency graph.

## Decisions & Alternatives

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Persist occurrences, not notifications | Stable records support reconciliation and personal Inbox removal isolation. | Recreate ephemeral notifications on every dashboard render. |
| Do not auto-delete edges | Dependency text is an operator-owned GitHub declaration. | Guess a low-priority edge to remove. |
