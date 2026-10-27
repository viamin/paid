# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResolveToolCall do
  # @spec CHAT-TURN-RECOVERY-001
  it "completes the originating turn after its final confirmation resumes the loop" do
    chat_session = create(:chat_session)
    user_message = create(:chat_message, chat_session:)
    turn = ChatTurn.start!(chat_session:, user_message:)
    tool_call = create(:chat_message, :tool_call, chat_session:, tool_status: "pending", tool_name: "search")
    client = instance_double(Proc, call: { content: "Done.", tool_calls: [], tokens_input: 1, tokens_output: 1, model: "test" })

    described_class.call(chat_session:, tool_call_message: tool_call, decision: :deny, llm_client: client)

    expect(turn.reload).to be_completed
  end
end
