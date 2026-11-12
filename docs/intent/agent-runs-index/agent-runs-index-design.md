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

The shared account and project filter form is a constrained Ransack surface.
It offers multi-select OR filters for status, agent type, goal, trigger type,
and effective runner, plus a text search across the allowlisted branch name,
workflow identifier, and run URLs. The filter form uses GET so its state is
shareable and retained through pagination. Active selections are announced to
operators and can be reset without affecting the route scope.

Queue-priority sorting only applies when every selected status is unfinished.
For any other status combination the normal Ransack ordering remains in force,
which avoids silently omitting terminal runs from a mixed selection.
