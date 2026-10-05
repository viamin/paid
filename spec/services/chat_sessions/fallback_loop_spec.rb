# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::FallbackLoop, type: :service do
  # @spec API-CONVERSATION-DELEGATION-003
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  it "keeps completed tool calls and results when discarding a failed runner attempt" do
    completed_call = create(:chat_message, chat_session: chat_session, role: "assistant",
      tool_name: "list_projects", tool_call_id: "call_complete")
    completed_result = create(:chat_message, chat_session: chat_session, role: "tool",
      tool_name: "list_projects", tool_call_id: "call_complete", tool_result: { "projects" => [] })
    partial_message = create(:chat_message, :assistant, chat_session: chat_session, content: "partial")

    fallback_host(chat_session).send(:discard_partial_attempt, [ completed_call.id, completed_result.id, partial_message.id ])

    expect(chat_session.messages.where(id: [ completed_call.id, completed_result.id ])).to exist
    expect(chat_session.messages.where(id: partial_message.id)).not_to exist
  end

  def fallback_host(session)
    Class.new do
      include ChatSessions::FallbackLoop

      def initialize(chat_session)
        @chat_session = chat_session
      end

      attr_reader :chat_session
    end.new(session)
  end
end
