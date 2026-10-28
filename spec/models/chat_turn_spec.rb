# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  describe "lifecycle" do
    it "records a stalled turn without representing it as completed" do
      turn = create(:chat_turn, :streaming, last_activity_at: 20.minutes.ago)

      turn.stall!(detected_at: Time.current, reason: "durable_activity_timeout")

      expect(turn).to have_attributes(status: "stalled", classification: "durable_activity_timeout")
      expect(turn.completed_at).to be_nil
      expect(turn.stalled_at).to be_present
    end

    it "does not classify a pending confirmation as stalled" do
      turn = create(:chat_turn, :awaiting_confirmation, last_activity_at: 20.minutes.ago)

      expect(turn.stallable?).to be(false)
    end
  end
end
