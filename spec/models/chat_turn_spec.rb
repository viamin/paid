# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  describe "#mark_stalled!" do
    # @spec CHAT-TURN-LIFECYCLE-003
    it "preserves partial work without representing the turn as successful" do
      turn = create(:chat_turn, status: "streaming")

      turn.mark_stalled!(classification: "infrastructure_failure", detected_at: Time.current)

      expect(turn).to have_attributes(status: "stalled", classification: "infrastructure_failure")
      expect(turn.completed_at).to be_nil
    end
  end

  describe "#claim_recovery!" do
    # @spec CHAT-TURN-LIFECYCLE-009
    it "allows only the first concurrent recovery claimant to proceed" do
      turn = create(:chat_turn, status: "stalled")

      expect(turn.claim_recovery!(to: "in_progress")).to be true
      expect(turn.claim_recovery!(to: "in_progress")).to be false
    end
  end
end
