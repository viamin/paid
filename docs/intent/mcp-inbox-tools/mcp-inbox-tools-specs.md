# EARS Specs: MCP Inbox Tools

- [x] **MCP-INBOX-TOOLS-001** — When an authenticated in-app agent calls
  `list_inbox_entries`, the system SHALL use `Inbox::Queue` with supported
  project, kind, scope, sort, limit, and cursor filters, default to actionable
  scope and a bounded small page, and return list-safe serializer envelopes
  with stable IDs and `next_cursor` only when another page exists.
  *Code:* `app/mcp/tools/list_inbox_entries.rb`.
  *Test:* `spec/mcp/tools/inbox_entries_spec.rb`.

- [x] **MCP-INBOX-TOOLS-002** — When an authenticated in-app agent calls
  `get_inbox_entry`, the system SHALL re-resolve the stable ID with
  `Inbox::FindEntry` and render its current detail with
  `Api::V1::InboxEntrySerializer`; an unavailable or unauthorized ID SHALL
  return the identical safe `{ found: false }` result.
  *Code:* `app/mcp/tools/get_inbox_entry.rb`.
  *Test:* `spec/mcp/tools/inbox_entries_spec.rb`.

- [x] **MCP-INBOX-TOOLS-003** — The MCP Inbox tools SHALL reuse the existing
  Inbox authorization and projection boundaries, remain read-only, and leave
  the chat-session MCP transport, confirmation, and rate limiting unchanged.
  *Code:* `app/mcp/tools/inbox_tool.rb`, `app/mcp/tools/registry.rb`.
  *Test:* `spec/mcp/tools/inbox_entries_spec.rb`, `spec/mcp/paid_mcp_server_spec.rb`.
