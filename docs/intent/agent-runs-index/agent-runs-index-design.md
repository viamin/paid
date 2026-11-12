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

The index uses its existing Ransack search object as its only filter contract.
Status, agent type, goal, effective runner, and trigger type controls submit
their selected values through `*_in` predicates, so selections within one
control are alternatives and selections across controls compose. The text
search control submits the allowlisted `run_text_cont` predicate, which
matches the displayed branch and custom-prompt context only. The form exposes
its active selections and reset action in the shareable GET URL.

Account-wide queue-priority sorting applies only if every selected status is
unfinished. When the status selection is empty or includes a finished status,
the account-wide index retains its normal newest-first ordering so queue
sorting cannot hide selected runs.
