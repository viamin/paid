# frozen_string_literal: true

require "rails_helper"

RSpec.describe Committee::Drivers do
  let(:schema_path) { Rails.root.join("docs/api/openapi.yaml") }
  let(:schema) { YAML.safe_load_file(schema_path) }

  # @spec MOBILE-API-006 MOBILE-API-016
  it "loads and has one discriminated branch for every inbox kind" do
    expect { described_class.load_from_file(schema_path, parser_options: { strict_reference_validation: true }) }
      .not_to raise_error

    %w[InboxEntry InboxEntryListItem].each do |schema_name|
      inbox_entry = schema.dig("components", "schemas", schema_name)
      mapping = inbox_entry.fetch("discriminator").fetch("mapping")
      branch_references = inbox_entry.fetch("oneOf").map { |branch| branch.fetch("$ref") }

      expect(mapping.keys).to match_array(Inbox::Queue::KINDS)
      expect(branch_references).to match_array(mapping.values)
    end
  end

  # @spec MOBILE-API-019
  it "documents the complete SSE event catalog on both streaming operations" do
    expected_events = %w[
      message_start message_chunk message_created message_tool_call
      message_tool_confirmation message_tool_result message_tool_resolved
      message_complete error
    ]

    streaming_operations = [
      schema.dig("paths", "/chat_sessions/{chat_session_id}/messages", "post"),
      schema.dig("paths", "/chat_sessions/{chat_session_id}/messages/{message_id}/resolve", "post")
    ]

    streaming_operations.each do |operation|
      expect(operation.dig("responses", "200", "content")).to have_key("text/event-stream")
      expect(operation.fetch("x-sse-events").fetch("$ref")).to eq("#/components/x-sse-events")
    end

    expect(schema.dig("components", "x-sse-events").keys).to match_array(expected_events)
  end

  # @spec MOBILE-API-009 MOBILE-API-016
  it "uses valid HTTP bearer requirements while documenting required PAT scopes" do
    scoped_operations = {
      "/inbox" => { "get" => [ "inbox" ] },
      "/inbox/count" => { "get" => [ "inbox" ] },
      "/inbox/entries/{entry_id}" => { "get" => [ "inbox" ] },
      "/inbox/entries/{entry_id}/chat" => { "post" => [ "chat" ] },
      "/chat_sessions" => { "get" => [ "chat" ], "post" => [ "chat" ] },
      "/chat_sessions/{id}" => { "get" => [ "chat" ], "patch" => [ "chat" ], "delete" => [ "chat" ] },
      "/chat_sessions/{id}/{transition}" => { "patch" => [ "chat" ] },
      "/chat_sessions/{chat_session_id}/messages" => { "get" => [ "chat" ], "post" => [ "chat" ] },
      "/chat_sessions/{chat_session_id}/messages/{message_id}/resolve" => { "post" => [ "chat" ] }
    }

    bearer_operations = schema.fetch("paths").values.flat_map do |path_item|
      path_item.values.select { |value| value.is_a?(Hash) && value.key?("security") }
    end

    bearer_operations.each do |operation|
      expect(operation.fetch("security")).to include("bearerAuth" => [])
    end

    scoped_operations.each do |path, operations|
      operations.each do |method, scopes|
        expect(schema.dig("paths", path, method, "x-required-pat-scopes")).to eq(scopes)
      end
    end
  end
end
