# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ProcessMessageJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  it "completes the durable turn after processing its response" do
    turn = create(:chat_turn, chat_session:, state: "pending", stream_message_id: "turn-stream")
    assistant = create(:chat_message, :assistant, chat_session:)
    allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant)

    described_class.perform_now(chat_session_id: chat_session.id, actor_id: user.id,
      content: "Hello", stream_message_id: "turn-stream", chat_turn_id: turn.id)

    expect(turn.reload).to have_attributes(state: "completed", assistant_message: assistant)
  end
end
