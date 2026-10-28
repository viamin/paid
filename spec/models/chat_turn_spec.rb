# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-026
  it "only exposes stale streaming turns to the detector" do
    stale = create(:chat_turn, status: "streaming", last_activity_at: 16.minutes.ago)
    create(:chat_turn, status: "streaming", last_activity_at: 2.minutes.ago)
    create(:chat_turn, status: "awaiting_confirmation", last_activity_at: 1.hour.ago)

    expect(described_class.stale_at(Time.current)).to contain_exactly(stale)
  end
end
