# frozen_string_literal: true

module Tools
  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  class ListInboxEntries < InboxTool
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    def self.tool_name = "list_inbox_entries"

    def self.description
      "List the current authorized Inbox entries. Defaults to actionable entries; use an entry ID with get_inbox_entry for full detail."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "Limit results to an accessible project" },
          kind: { type: "string", enum: Inbox::Queue::KINDS, description: "Inbox entry kind" },
          scope: { type: "string", enum: Inbox::Queue::SCOPES, default: Inbox::Queue::ACTIONABLE_SCOPE },
          sort: { type: "string", enum: Inbox::Queue::SORTS.keys, default: Inbox::Queue::DEFAULT_SORT },
          limit: { type: "integer", default: DEFAULT_LIMIT, description: "Maximum entries (1-100)" },
          cursor: { type: "string", description: "Entry ID returned as next_cursor by a previous call" }
        }
      }
    end

    def perform(project_id: nil, kind: nil, scope: nil, sort: nil, limit: DEFAULT_LIMIT, cursor: nil)
      entries = Inbox::Queue.call(
        user:,
        project: project_id.present? ? project_for(project_id) : nil,
        kind: valid_kind(kind),
        scope: valid_scope(scope),
        sort: valid_sort(sort)
      )
      page = entries_after_cursor(entries, cursor).first(bounded_limit(limit) + 1)
      listed_entries = page.first(bounded_limit(limit))

      { entries: listed_entries.map { |entry| Api::V1::InboxEntrySerializer.render_list(entry) },
        next_cursor: page.size > bounded_limit(limit) ? listed_entries.last.id : nil }.compact
    end

    private

    # Mirrors Api::V1::InboxController#inbox_limit: an explicit null or blank
    # limit means the default page, not the minimum page size.
    def bounded_limit(limit)
      return DEFAULT_LIMIT if limit.blank?

      limit.to_i.clamp(1, MAX_LIMIT)
    end

    def entries_after_cursor(entries, cursor)
      return entries if cursor.blank?

      cursor_index = entries.index { |entry| entry.id == cursor }
      cursor_index ? entries.drop(cursor_index + 1) : []
    end
  end
end
