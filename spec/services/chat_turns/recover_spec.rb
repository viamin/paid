# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Recover do
  # @spec CHAT-API-028
  it "claims a stalled turn once before an explicit retry" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session, content: "Deploy it")
    turn = ChatTurn.create!(chat_session: session, user_message:, state: "stalled", activity_at: Time.current)
    allow(ChatSessions::SendMessage).to receive(:call)

    described_class.call(turn:, actor: session.created_by)

    expect(turn.reload).to have_attributes(state: "streaming", recovery_attempts: 1)
    expect(ChatSessions::SendMessage).to have_received(:call).with(hash_including(user_message:, content: "Deploy it"))
    expect {
      described_class.call(turn:, actor: session.created_by)
    }.to raise_error(described_class::NotRecoverable)
  end
end
