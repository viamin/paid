# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-API-027
  it "marks an inactive active turn stalled and preserves a transcript notice" do
    chat_session = create(:chat_session)
    user_message = create(:chat_message, chat_session:, role: "user")
    turn = ChatTurn.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      state: "streaming", last_activity_at: 11.minutes.ago)

    described_class.perform_now

    expect(turn.reload.state).to eq("stalled")
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end
end
