# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::StallSweepJob do
  # @spec CHAT-TURN-002
  it "detects only turns beyond the configured inactivity threshold" do
    account = create(:account)
    user = create(:user, account:)
    session = create(:chat_session, account:, created_by: user)
    stale = create(:chat_turn, chat_session: session, last_activity_at: 16.minutes.ago)
    fresh = create(:chat_turn, chat_session: session, last_activity_at: 1.minute.ago)

    described_class.perform_now

    expect(stale.reload.status).to eq("stalled")
    expect(fresh.reload.status).to eq("streaming")
  end
end
