# frozen_string_literal: true

require "rails_helper"

# End-to-end security coverage for RDR-028: a write tool requested by the model
# never mutates state until a human explicitly approves it. Uses a real write
# tool (`update_user_settings`) with an observable side effect.
RSpec.describe "Chat write-tool confirmation security", type: :model do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  before { create(:user_setting, user: user) }

  def requested_write_tool_response
    {
      content: "I'll update your settings.",
      tool_calls: [
        {
          id: "call_1",
          name: "update_user_settings",
          arguments: { "settings" => { "theme_preference" => "dark" }, "confirmed" => true }
        }
      ],
      tokens_input: 40,
      tokens_output: 20,
      model: "gpt-4o"
    }
  end

  def final_response
    { content: "All done.", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
  end

  def stateful_client(responses)
    Class.new do
      attr_reader :seen_conversations

      def initialize(responses)
        @responses = responses
        @index = 0
        @seen_conversations = []
      end

      def call(conversation, tools: nil)
        @seen_conversations << conversation
        @index += 1
        @responses.fetch(@index - 1)
      end
    end.new(responses)
  end

  def pause_for_write_tool(client:)
    ChatSessions::SendMessage.call(chat_session: chat_session, content: "Switch my theme", llm_client: client)
  end

  describe "an unapproved write tool never mutates state" do
    let(:client) { stateful_client([ requested_write_tool_response, final_response ]) }
    let(:pending_message) { chat_session.messages.find_by(tool_status: "pending") }

    before { pause_for_write_tool(client: client) }

    it "pauses instead of executing, leaving the pending request and no mutation" do
      expect(pending_message).to be_present
      expect(pending_message.tool_name).to eq("update_user_settings")
      expect(chat_session.messages.where(role: "tool")).not_to exist
      expect(user.settings.reload.theme_preference).to eq("system")
    end

    it "does not mutate state when denied and feeds a denied result back to the model" do
      ChatSessions::ResolveToolCall.call(
        chat_session: chat_session, tool_call_message: pending_message,
        decision: :deny, llm_client: client
      )

      tool_result = chat_session.messages.find_by(role: "tool")
      expect(tool_result.tool_result).to include("status" => "denied")
      expect(user.settings.reload.theme_preference).to eq("system")
    end
  end

  describe "an approved write tool mutates state" do
    let(:client) { stateful_client([ requested_write_tool_response, final_response ]) }
    let(:pending_message) { chat_session.messages.find_by(tool_status: "pending") }

    before { pause_for_write_tool(client: client) }

    it "executes only after explicit approval" do
      ChatSessions::ResolveToolCall.call(
        chat_session: chat_session, tool_call_message: pending_message,
        decision: :approve, llm_client: client
      )

      expect(user.settings.reload.theme_preference).to eq("dark")
      tool_result = chat_session.messages.find_by(role: "tool")
      expect(tool_result.tool_result).to include("theme_preference" => "dark")
    end
  end

  describe "the confirmation survives reconnect" do
    it "still resolves a persisted pending tool call after reloading the session" do
      client = stateful_client([ requested_write_tool_response, final_response ])
      pause_for_write_tool(client: client)
      pending_id = chat_session.messages.find_by(tool_status: "pending").id

      reloaded_session = ChatSession.find(chat_session.id)
      reloaded_pending = reloaded_session.messages.find(pending_id)

      ChatSessions::ResolveToolCall.call(
        chat_session: reloaded_session, tool_call_message: reloaded_pending,
        decision: :approve, llm_client: client
      )

      expect(reloaded_pending.reload.tool_status).to eq("approved")
      expect(user.settings.reload.theme_preference).to eq("dark")
    end
  end
end
