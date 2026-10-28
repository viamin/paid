# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  # @spec CHAT-TURN-RECOVERY-004
  it "finds only non-terminal turns with expired durable activity" do
    session = create(:chat_session)
    stale = create(:chat_turn, chat_session: session, status: "streaming", last_activity_at: 11.minutes.ago)
    create(:chat_turn, chat_session: session, status: "completed", last_activity_at: 11.minutes.ago)
    create(:chat_turn, chat_session: session, status: "streaming", last_activity_at: 1.minute.ago)

    expect(described_class.stale_before(10.minutes.ago)).to contain_exactly(stale)
  end
end
