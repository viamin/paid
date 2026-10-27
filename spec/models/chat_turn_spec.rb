# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  # @spec CHAT-TURN-001 CHAT-TURN-002
  it "does not consider a turn waiting for confirmation stalled" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "pending")

    expect(turn.stall_eligible?(at: Time.current)).to be(false)
  end
end
