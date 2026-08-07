# Chat Tool Confirmation Design

prefix: CHAT-TOOL-CONFIRMATION

Interactive chat can propose write tools, but the model must not be able to
self-authorize those mutations. Paid advertises write tools without their
`confirmed` argument, persists the proposed call as a pending chat message, and
injects `confirmed: true` only after a human approves the tool call.

Each pre-dispatch GitHub issue write tool (`create_issue`, `edit_issue`, and
`set_labels`) therefore owns a uniform execution guard: unconfirmed calls fail
before side effects, while approved chat resolutions and explicit MCP clients
that pass `confirmed: true` can proceed through normal Pundit authorization and
tool execution.

## Auto-approve eligibility

The per-session "Auto-approve actions" toggle lets a session owner skip the
manual confirmation click for a scoped set of reversible write tools. Rather
than hardcoding tool names in the agent loop, each tool declares its own
`auto_approve_eligible?` (default `false`): `trigger_agent_run` and the GitHub
issue write tools (`create_issue`, `edit_issue`, `set_labels`) opt in because
their effects are reversible and scoped to a single repo or run, while
higher-blast-radius mutations — settings, memberships, API keys, and Change
Intent Records — keep RDR-028's manual-confirmation default. `confirmed` is
still injected by the loop on the human's behalf (exactly as a manual approval
does); it never originates from the model.
