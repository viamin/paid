# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  describe ".call" do
    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-007
    it "marks stale streaming turns, preserves evidence, and writes one durable notice" do
      turn = create(:chat_turn, status: "streaming", last_activity_at: 6.minutes.ago)

      expect { described_class.call(timeout: 5.minutes) }
        .to change { turn.chat_session.messages.where(role: "system").count }.by(1)

      expect(turn.reload).to have_attributes(status: "stalled", detected_at: be_present)
      notice = turn.chat_session.messages.order(:id).last
      expect(notice).to be_stalled_turn_notice
      expect(notice.metadata).to include("chat_turn_id" => turn.id, "recovery_requires_confirmation" => true)
    end

    # @spec CHAT-TURN-RECOVERY-002
    it "does not stall a pending confirmation or a declared long-running operation" do
      pending = create(:chat_turn, status: "pending", last_activity_at: 1.hour.ago)
      long_running = create(:chat_turn, status: "streaming", last_activity_at: 1.hour.ago,
        metadata: { "long_running_until" => 1.hour.from_now.iso8601 })

      described_class.call(timeout: 5.minutes)

      expect([ pending.reload.status, long_running.reload.status ]).to all(eq("pending").or(eq("streaming")))
    end
  end
end
