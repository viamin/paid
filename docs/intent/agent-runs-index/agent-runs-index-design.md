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

The account-wide run list selects only columns needed by its table. Large
structured execution payloads are omitted from each paginated page; the
custom prompt remains available for runs without an issue or PR context.

Both account-wide and project-scoped indexes use the Agent Run Ransack
allowlist as their filtering contract. Categorical controls submit `*_in`
arrays, so selections within one field are ORed while different fields compose.
The text search is limited to branch names and Temporal workflow identifiers.
The account-wide queue ordering is available only when every selected status is
unfinished; otherwise the index keeps its normal newest-first ordering.
