# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  describe ".stale_candidates" do
    it "returns inactive streaming turns but excludes confirmation pauses" do
      stale = create(:chat_turn, last_activity_at: 20.minutes.ago)
      create(:chat_turn, last_activity_at: 20.minutes.ago, pause_reason: "confirmation")
      create(:chat_turn, last_activity_at: 1.minute.ago)

      expect(described_class.stale_candidates(15.minutes.ago)).to contain_exactly(stale)
    end
  end

  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-007
  it "records terminal outcomes without converting stalls to completion" do
    turn = create(:chat_turn, status: "stalled", detected_stalled_at: Time.current)

    expect(turn.complete!).to be(false)
    expect(turn.reload.status).to eq("stalled")
  end
end
