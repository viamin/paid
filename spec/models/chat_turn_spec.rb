# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  describe ".stale" do
    # @spec CHAT-TURN-RECOVERY-001
    it "returns streaming turns whose durable activity has exceeded the timeout" do
      stale = create(:chat_turn, status: "streaming", last_activity_at: 6.minutes.ago)
      create(:chat_turn, status: "streaming", last_activity_at: 4.minutes.ago)
      create(:chat_turn, status: "pending", last_activity_at: 1.hour.ago)

      expect(described_class.stale(timeout: 5.minutes)).to contain_exactly(stale)
    end
  end
end
