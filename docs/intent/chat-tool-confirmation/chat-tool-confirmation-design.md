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
