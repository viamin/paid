---
parent: PAID
prefix: MCP-INBOX-TOOLS
---

# Low-Level Design: MCP Inbox Tools

## Purpose

An authenticated in-app agent needs to discover its user's current Inbox work
and inspect one selected item without UI navigation or a second Inbox model.

## Approach

The existing chat-session MCP server exposes two read-only `Tools::*` tools:

- `list_inbox_entries` accepts the REST Inbox list filters (`project_id`,
  `kind`, `scope`, `sort`, `limit`, and `cursor`), defaults to actionable
  scope and a small bounded page, and renders each row through
  `Api::V1::InboxEntrySerializer.render_list`.
- `get_inbox_entry` accepts one stable queue ID and re-resolves it through
  `Inbox::FindEntry`; it renders the selected row through
  `Api::V1::InboxEntrySerializer.render`. It returns `{ found: false }` when
  queue re-resolution no longer admits the ID, without distinguishing stale
  from unauthorized records.

The tools call `Inbox::Queue`, `Inbox::FindEntry`, and the existing serializer
directly. List pagination occurs before serialization, so a list does not load
detail-only evidence or make remote calls per row. `InboxTool` authorizes the
authenticated user with `InboxPolicy`; project filters resolve through the
existing `policy_scope(Project)` boundary. Queue re-resolution retains the
existing project visibility, phase scopes, personal-removal, and session/user
eligibility behavior. Detail follows the REST API's all-scope lookup semantics:
a currently authorized entry remains inspectable even when it is outside the
default actionable list because it is removed or in a disabled phase.

## Boundaries

These tools are read-only and do not dismiss, close, approve, or start work.
They use the existing MCP confirmation and rate-limit behavior unchanged.
They are available only through Paid's authenticated in-app chat-session MCP
endpoint; this does not make that endpoint an external-agent API. External
clients continue to use the scoped bearer-token Inbox REST API or a separately
authorized connector.
