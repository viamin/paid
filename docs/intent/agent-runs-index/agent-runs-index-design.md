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

## Filtering and search

Both the account-wide and project-scoped indexes use the same allowlisted
Ransack query contract. Status, agent type, goal, effective runner, and trigger
type are multi-select `*_in` controls: values within a control have OR
semantics, while controls and the text search compose with AND semantics. The
text search is deliberately limited to branch name and Temporal workflow ID;
it does not expose arbitrary run attributes or diagnostic text.

The active query remains in the GET URL, including pagination and table sort
state. The filter surface names active selections and provides a reset link.
Queue-priority sorting applies only when every selected status is unfinished;
otherwise the index keeps the normal Ransack sort so it never silently removes
completed or failed records from a mixed-status result.

The account-wide run list selects only columns needed by its table. Large
structured execution payloads are omitted from each paginated page; the
custom prompt remains available for runs without an issue or PR context.
