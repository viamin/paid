# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::SendMessage do
  describe "#build_conversation" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:chat_session) { create(:chat_session, account: account, created_by: user) }
    let(:service) { described_class.new(chat_session: chat_session, content: "Follow-up") }

    it "regroups persisted assistant tool-call rows onto the preceding assistant message" do
      create(:chat_message, :system, chat_session: chat_session)
      create(:chat_message, chat_session: chat_session, role: "user", content: "Search for test")
      create(:chat_message, :assistant, chat_session: chat_session, content: "Let me search for that.")
      create_tool_roundtrip_rows(result: tool_result)

      expect(service.send(:build_conversation)).to include(
        regrouped_assistant_entry("Let me search for that."),
        tool_entry(tool_result)
      )
    end

    it "recreates assistant tool-call entries even when the original response had no assistant text" do
      create(:chat_message, chat_session: chat_session, role: "user", content: "Search for test")
      create_tool_roundtrip_rows(result: { "status" => "ok" })

      expect(service.send(:build_conversation)).to include(
        {
          role: "assistant",
          content: nil,
          tool_calls: [
            {
              id: "call_1",
              name: "search",
              arguments: { "query" => "test" }
            }
          ]
        }
      )
    end

    def tool_result
      { "status" => "ok", "results" => [ "match" ] }
    end

    def regrouped_assistant_entry(content)
      {
        role: "assistant",
        content: content,
        tool_calls: [
          {
            id: "call_1",
            name: "search",
            arguments: { "query" => "test" }
          }
        ]
      }
    end

    def tool_entry(result)
      {
        role: "tool",
        content: result,
        tool_call_id: "call_1",
        tool_name: "search"
      }
    end

    def create_tool_roundtrip_rows(result:)
      create(
        :chat_message,
        :tool_call,
        chat_session: chat_session,
        tool_call_id: "call_1",
        tool_name: "search",
        tool_arguments: { "query" => "test" }
      )
      create(
        :chat_message,
        :tool,
        chat_session: chat_session,
        tool_call_id: "call_1",
        tool_name: "search",
        content: result.to_json,
        tool_result: result
      )
    end
  end
end
