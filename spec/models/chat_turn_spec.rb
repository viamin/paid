# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  describe ".overdue" do
    it "finds only unfinished turns without durable activity past the threshold" do # @spec CHAT-TURN-RECOVERY-001
      overdue = create(:chat_turn, last_activity_at: 11.minutes.ago)
      create(:chat_turn, last_activity_at: 1.minute.ago)
      create(:chat_turn, :waiting_for_confirmation, last_activity_at: 11.minutes.ago)

      expect(described_class.overdue).to contain_exactly(overdue)
    end
  end
end
