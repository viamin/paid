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

The index uses the Agent Run Ransack allowlist as its only filtering contract.
Categorical controls submit `*_in` arrays so selections within one field use
OR semantics; text search is limited to the allowlisted branch name and custom
prompt fields. The form retains its `q` query in pagination and sort links,
shows active selections, and provides a reset link. Queue-priority ordering is
available only when every selected status is unfinished, because its scope
intentionally excludes finished runs.
