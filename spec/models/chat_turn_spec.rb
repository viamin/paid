# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  describe ".stale" do
    # @spec CHAT-API-027
    it "finds only non-terminal turns without recent durable activity" do
      stale_turn = create(:chat_turn, :streaming, last_activity_at: 11.minutes.ago)
      create(:chat_turn, :streaming, last_activity_at: 1.minute.ago)
      create(:chat_turn, :completed, last_activity_at: 11.minutes.ago)

      expect(described_class.stale(10.minutes)).to contain_exactly(stale_turn)
    end
  end
end
