# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  describe "#stall_if_eligible!" do
    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
    it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
      turn = create(:chat_turn, last_activity_at: 6.minutes.ago)

      expect(turn.stall_if_eligible!(cutoff: 5.minutes.ago)).to be true
      expect(turn.reload.status).to eq("stalled")
      expect(turn.messages.last).to be_stalled_turn_notice
      expect(turn.messages.last.content).to include("no tool calls were replayed automatically")
    end

    # @spec CHAT-TURN-RECOVERY-002
    it "does not classify a turn waiting for a tool confirmation as stalled" do
      turn = create(:chat_turn, last_activity_at: 6.minutes.ago)
      create(:chat_message, :tool_call, chat_session: turn.chat_session, chat_turn: turn, tool_status: "pending")

      expect(turn.stall_if_eligible!(cutoff: 5.minutes.ago)).to be false
      expect(turn.reload.status).to eq("streaming")
    end
  end
end
