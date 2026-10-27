# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-RECOVERY-002
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:) }

  it "stalls inactive streaming turns and preserves an actionable transcript notice" do
    turn = ChatTurn.start!(chat_session:, user_message:)
    turn.update!(last_activity_at: 20.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to be_stalled
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn awaiting an explicit confirmation" do
    turn = ChatTurn.start!(chat_session:, user_message:)
    turn.await_confirmation!
    turn.update!(last_activity_at: 20.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to be_pending_confirmation
  end

  it "does not stall a turn paused for a known provider rate limit" do
    turn = ChatTurn.start!(chat_session:, user_message:)
    chat_session.update!(rate_limited_until: 10.minutes.from_now)
    turn.update!(last_activity_at: 20.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to be_streaming
  end
end
