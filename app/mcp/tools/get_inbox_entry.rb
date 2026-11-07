# frozen_string_literal: true

module Tools
  # @spec MCP-INBOX-TOOLS-002 MCP-INBOX-TOOLS-003
  class GetInboxEntry < InboxTool
    def self.tool_name = "get_inbox_entry"

    def self.description
      "Get the current authorized detail for one Inbox entry ID. Returns found: false when the entry is stale or unavailable."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          entry_id: { type: "string", description: "Stable Inbox entry ID from list_inbox_entries" }
        },
        required: [ "entry_id" ]
      }
    end

    def perform(entry_id:)
      entry = Inbox::FindEntry.call(user:, entry_id:)
      return { found: false } unless entry

      { found: true, entry: Api::V1::InboxEntrySerializer.render(entry, user:) }
    end
  end
end
