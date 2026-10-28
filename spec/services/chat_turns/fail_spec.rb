# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Fail do
  # @spec CHAT-TURN-RECOVERY-002
  it "records a durable failure outcome once instead of silently leaving an active turn" do
    chat_session = create(:chat_session)
    turn = create(:chat_turn, chat_session:, state: "streaming")

    expect {
      described_class.call(chat_turn: turn, classification: "provider_error", message: "Runner failed")
    }.to change { chat_session.messages.count }.by(1)

    expect(turn.reload).to have_attributes(state: "failed", failure_classification: "provider_error")
    expect(chat_session.messages.last).to be_chat_turn_failure_notice
    expect {
      described_class.call(chat_turn: turn, classification: "provider_error", message: "Runner failed")
    }.not_to change { chat_session.messages.count }
  end
end
