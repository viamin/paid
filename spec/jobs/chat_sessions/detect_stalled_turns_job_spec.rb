# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "classifies only stale streaming turns and does not replay their tools" do
    stale_turn = create(:chat_turn, last_activity_at: 6.minutes.ago)
    current_turn = create(:chat_turn, last_activity_at: 1.minute.ago)

    described_class.perform_now

    expect(stale_turn.reload.status).to eq("stalled")
    expect(current_turn.reload.status).to eq("streaming")
    expect(stale_turn.messages.where(role: "tool")).to be_empty
  end
end
