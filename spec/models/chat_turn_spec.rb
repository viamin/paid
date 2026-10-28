# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "marks inactive turns stalled but preserves pending confirmations" do
    turn = create(:chat_turn, :streaming, last_activity_at: 10.minutes.ago)
    waiting = create(:chat_turn, :streaming, last_activity_at: 10.minutes.ago)
    create(:chat_message, :tool_call, chat_session: waiting.chat_session, tool_status: "pending")

    expect(described_class.stale_before(5.minutes.ago)).to contain_exactly(turn)
  end
end
