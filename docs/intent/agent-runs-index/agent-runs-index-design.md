---
parent: root
prefix: AGENT-RUNS-INDEX
---

# Agent Runs index

The Agent Runs index exposes controls for values that exist in the current
authorized, non-synthetic run scope. Its filter section is collapsed until the
operator opens it, keeping the page consistent with the Inbox filter surface.
Filter values are cached independently for account-wide and project-scoped
views. Agent Run changes that affect the available values invalidate both
corresponding entries.

The index uses the existing Ransack query object as its only filtering
contract. Status, agent type, goal, effective runner, and trigger type use
allowlisted `_in` predicates so selecting several values means any selected
value for that field. The search field uses the allowlisted
`branch_name_or_temporal_workflow_id_cont` predicate. These filters compose
through the shareable `q` GET parameter on both index routes; pagination and
table sort links retain that query state. The controls use native multi-select
elements, explicit labels, a visible active-filter summary, and a reset link.

Queue-priority ordering is available only when exactly one selected status is
unfinished. With no status, a completed status, or multiple statuses, the
index uses its normal newest-first ordering so queue ordering never silently
removes matching terminal runs.

The account-wide run list selects only columns needed by its table. Large
structured execution payloads are omitted from each paginated page; the
custom prompt remains available for runs without an issue or PR context.
