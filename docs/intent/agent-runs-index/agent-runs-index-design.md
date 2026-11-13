---
parent: root
prefix: AGENT-RUNS-INDEX
---

# Agent Runs index

The Agent Runs index exposes Ransack-backed controls for values that exist in
the current authorized, non-synthetic run scope. Its filter section is
collapsed until the operator opens it, keeping the page consistent with the
Inbox filter surface. Categorical controls submit `*_in` predicates so an
operator can select multiple statuses, agent types, goals, effective runners,
or trigger types; values within one control have OR semantics and controls
compose with one another. The text search field is deliberately limited to the
allowlisted branch name and Temporal workflow identifier predicate, rather
than accepting arbitrary model attributes.

The current selections are visible as active filters and remain in the GET
URL, including pagination links. A reset link returns to the unfiltered index.
Native multi-select controls retain keyboard and screen-reader semantics.
Filter values are cached independently for account-wide and project-scoped
views. Agent Run changes that affect the available values invalidate both
corresponding entries.

Queue-priority sorting only applies when every selected status is unfinished.
When a selection includes a finished status, the index uses its ordinary
Ransack/default ordering so it never silently drops matching rows.

The account-wide run list selects only columns needed by its table. Large
structured execution payloads are omitted from each paginated page; the
custom prompt remains available for runs without an issue or PR context.
