# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user") }

  # @spec CHAT-API-027
  it "does not classify a pending confirmation as stalled" do
    turn = described_class.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      state: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, chat_session:, role: "assistant", tool_status: "pending")

    expect(turn.reload.stallable?).to be(false)
  end

  # @spec CHAT-API-027
  it "classifies an inactive non-terminal turn as stalled" do
    turn = described_class.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      state: "streaming", last_activity_at: 20.minutes.ago)

    expect { turn.stall! }.to change { chat_session.messages.where(role: "system").count }.by(1)
    expect(turn.reload).to have_attributes(state: "stalled", stalled_at: be_present)
    expect(chat_session.messages.last.metadata).to include("chat_turn_stalled" => true, "chat_turn_id" => turn.id)
  end
end
