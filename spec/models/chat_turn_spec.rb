# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-002
  it "finds only active turns older than the configured threshold" do
    session = create(:chat_session)
    old_message = create(:chat_message, chat_session: session)
    fresh_message = create(:chat_message, chat_session: session)
    old = described_class.create!(chat_session: session, initiating_message: old_message, status: "streaming", last_activity_at: 11.minutes.ago)
    described_class.create!(chat_session: session, initiating_message: fresh_message, status: "completed", last_activity_at: 11.minutes.ago)

    expect(described_class.stale_before(10.minutes.ago)).to contain_exactly(old)
  end
end
