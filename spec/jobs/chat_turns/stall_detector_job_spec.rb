# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::StallDetectorJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:threshold) { ChatTurns::StallDetectorJob::STALL_THRESHOLD.call }

  describe "#perform" do
    # @spec CHAT-TURN-RECOVERY-002
    it "marks a turn with no durable activity beyond the threshold as stalled" do
      turn = create(:chat_turn, :write_tool_dispatched, chat_session: chat_session,
        last_activity_at: (threshold + 60).seconds.ago)

      described_class.perform_now

      expect(turn.reload.status).to eq("stalled")
      expect(turn.stall_detected_at).to be_present
    end

    it "does not touch turns within the threshold" do
      turn = create(:chat_turn, chat_session: chat_session, last_activity_at: (threshold - 60).seconds.ago)

      described_class.perform_now

      expect(turn.reload.status).to eq("streaming")
    end

    # @spec CHAT-TURN-RECOVERY-002
    it "does not mark a turn as stalled while a write-tool confirmation is pending" do
      turn = create(:chat_turn, chat_session: chat_session, last_activity_at: (threshold + 60).seconds.ago)
      create(:chat_message, :tool_call, chat_session: chat_session, tool_status: "pending")

      described_class.perform_now

      expect(turn.reload.status).to eq("streaming")
    end

    it "does not mark a turn as stalled during its documented long-running window" do
      turn = create(:chat_turn, chat_session: chat_session,
        last_activity_at: (threshold + 60).seconds.ago,
        metadata: { "expected_long_running_until" => 5.minutes.from_now.iso8601 })

      described_class.perform_now

      expect(turn.reload.status).to eq("streaming")
    end

    it "persists and broadcasts an in-transcript notice" do
      turn = create(:chat_turn, chat_session: chat_session, last_activity_at: (threshold + 60).seconds.ago)

      expect {
        described_class.perform_now
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_created"))

      notice = chat_session.messages.order(:id).last
      expect(notice.stalled_turn_notice?).to be(true)
      expect(notice.metadata["chat_turn_id"]).to eq(turn.id)
    end

    # @spec CHAT-TURN-RECOVERY-004
    it "attempts bounded automatic recovery when no write tool has been dispatched" do
      turn = create(:chat_turn, chat_session: chat_session,
        last_activity_at: (threshold + 60).seconds.ago,
        metadata: { "recovery_classification" => "infrastructure_failure" })

      expect(ChatTurns::RecoverStalledTurnJob).to receive(:perform_later).with(
        hash_including(chat_turn_id: turn.id, triggered_by: "automatic")
      )

      described_class.perform_now

      expect(turn.reload.recovery_attempts).to eq(1)
    end

    # @spec CHAT-TURN-RECOVERY-005
    it "does not attempt automatic recovery once a write tool has been dispatched" do
      turn = create(:chat_turn, :write_tool_dispatched, chat_session: chat_session,
        last_activity_at: (threshold + 60).seconds.ago)

      expect(ChatTurns::RecoverStalledTurnJob).not_to receive(:perform_later)

      described_class.perform_now

      expect(turn.reload.status).to eq("stalled")
      expect(turn.recovery_attempts).to eq(0)
    end

    it "does not attempt automatic recovery for an ambiguous silent stop" do
      turn = create(:chat_turn, chat_session: chat_session, last_activity_at: (threshold + 60).seconds.ago)

      expect(ChatTurns::RecoverStalledTurnJob).not_to receive(:perform_later)

      described_class.perform_now

      expect(turn.reload.status).to eq("stalled")
    end
  end
end
