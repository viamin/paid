# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session: chat_session) }

  describe ".start!" do
    # @spec CHAT-TURN-RECOVERY-001
    it "creates a pending turn for a new user message" do
      turn = described_class.start!(chat_session: chat_session, user_message: user_message)

      expect(turn.status).to eq("pending")
      expect(turn.chat_session).to eq(chat_session)
      expect(turn.user_message).to eq(user_message)
      expect(turn.last_activity_at).to be_present
    end

    it "reuses the existing turn without bypassing its stalled recovery gate" do
      first = described_class.start!(chat_session: chat_session, user_message: user_message)
      first.update!(status: "stalled")

      expect {
        described_class.start!(chat_session: chat_session, user_message: user_message)
      }.not_to change(described_class, :count)

      expect(first.reload.status).to eq("stalled")
    end
  end

  describe "#record_activity!" do
    let(:turn) { described_class.start!(chat_session: chat_session, user_message: user_message) }

    it "transitions a pending turn to streaming and bumps last_activity_at" do
      message = create(:chat_message, :assistant, chat_session: chat_session)

      expect { turn.record_activity!(message) }.to change(turn, :last_activity_at)
      expect(turn.status).to eq("streaming")
    end

    it "marks write_tool_dispatched when a write tool call is persisted" do
      message = build(:chat_message, :tool_call, chat_session: chat_session, tool_name: "create_issue")
      allow(Tools::Registry).to receive(:write_tool?).with("create_issue").and_return(true)
      message.save!

      turn.record_activity!(message)

      expect(turn.write_tool_dispatched).to be(true)
    end

    it "does not mark write_tool_dispatched for a read-only tool call" do
      message = create(:chat_message, :tool_call, chat_session: chat_session, tool_name: "list_repo_tree")
      allow(Tools::Registry).to receive(:write_tool?).with("list_repo_tree").and_return(false)

      turn.record_activity!(message)

      expect(turn.write_tool_dispatched).to be(false)
    end
  end

  describe "#heartbeat_callback" do
    # @spec CHAT-TURN-RECOVERY-001 @spec CHAT-TURN-RECOVERY-002
    it "durably refreshes attempt liveness and forwards the streamed chunk" do
      turn = described_class.start!(chat_session: chat_session, user_message: user_message)
      original_heartbeat = turn.attempt_heartbeat_at
      chunks = []

      travel described_class::HEARTBEAT_INTERVAL + 1.second
      turn.heartbeat_callback(->(chunk) { chunks << chunk }).call("Still working")

      expect(turn.reload.attempt_heartbeat_at).to be > original_heartbeat
      expect(chunks).to eq([ "Still working" ])
    end
  end

  describe "#complete!" do
    it "marks the turn completed and records a lifecycle event" do
      turn = described_class.start!(chat_session: chat_session, user_message: user_message)
      assistant_message = create(:chat_message, :assistant, chat_session: chat_session)

      turn.complete!(assistant_message)

      expect(turn.status).to eq("completed")
      expect(turn.completed_at).to be_present
      expect(turn.lifecycle_events.pluck(:event_name)).to include("chat_turn.completed")
    end
  end

  describe "#fail!" do
    it "classifies a provider error and records a lifecycle event" do
      turn = described_class.start!(chat_session: chat_session, user_message: user_message)

      turn.fail!(error: ArgumentError.new("bad content"))

      expect(turn.status).to eq("failed")
      expect(turn.failure_classification).to eq("validation_error")
      expect(turn.lifecycle_events.pluck(:event_name)).to include("chat_turn.failed")
    end
  end

  describe "#claim_recovery!" do
    let(:turn) { create(:chat_turn, :stalled, chat_session: chat_session) }

    # @spec CHAT-TURN-RECOVERY-006
    it "transitions a stalled turn to streaming and bumps recovery_attempts" do
      expect(turn.claim_recovery!(triggered_by: "manual")).to be(true)
      expect(turn.status).to eq("streaming")
      expect(turn.recovery_attempts).to eq(1)
      expect(turn.lifecycle_events.pluck(:event_name)).to include("chat_turn.recovery_attempted")
    end

    it "rejects a second concurrent claim on the same turn" do
      turn.claim_recovery!(triggered_by: "automatic")

      expect(turn.claim_recovery!(triggered_by: "manual")).to be(false)
      expect(turn.lifecycle_events.pluck(:event_name)).to include("chat_turn.recovery_duplicate_prevented")
    end

    it "does nothing when the turn is not currently stalled" do
      turn.update!(status: "completed")

      expect(turn.claim_recovery!(triggered_by: "manual")).to be(false)
    end

    it "abandons an exhausted stalled turn instead of starting another recovery" do
      turn.update!(recovery_attempts: described_class::MAX_RECOVERY_ATTEMPTS)

      expect(turn.claim_recovery!(triggered_by: "manual")).to be(false)

      expect(turn.reload.status).to eq("abandoned")
      expect(turn.lifecycle_events.pluck(:event_name)).to include("chat_turn.abandoned")
    end
  end

  describe "#eligible_for_automatic_recovery?" do
    it "is eligible when stalled with no write tool dispatched and no prior attempts" do
      turn = create(:chat_turn, :stalled, chat_session: chat_session,
        metadata: { "recovery_classification" => "infrastructure_failure" })

      expect(turn.eligible_for_automatic_recovery?).to be(true)
    end

    it "is not eligible once a write tool has been dispatched" do
      turn = create(:chat_turn, :stalled, :write_tool_dispatched, chat_session: chat_session,
        metadata: { "recovery_classification" => "infrastructure_failure" })

      expect(turn.eligible_for_automatic_recovery?).to be(false)
    end

    it "is not eligible once the automatic recovery attempt bound is reached" do
      turn = create(:chat_turn, :stalled, chat_session: chat_session,
        recovery_attempts: described_class::MAX_AUTOMATIC_RECOVERY_ATTEMPTS,
        metadata: { "recovery_classification" => "infrastructure_failure" })

      expect(turn.eligible_for_automatic_recovery?).to be(false)
    end

    it "is not eligible when a silent stop has no infrastructure classification" do
      turn = create(:chat_turn, :stalled, chat_session: chat_session)

      expect(turn.eligible_for_automatic_recovery?).to be(false)
    end
  end

  describe "#awaiting_confirmation?" do
    let(:turn) { create(:chat_turn, chat_session: chat_session) }

    it "is true when the session has a pending tool confirmation" do
      create(:chat_message, :tool_call, chat_session: chat_session, tool_status: "pending")

      expect(turn.awaiting_confirmation?).to be(true)
    end

    it "is false otherwise" do
      expect(turn.awaiting_confirmation?).to be(false)
    end
  end

  describe "#expected_long_running?" do
    it "is true while the durable long-running checkpoint has not expired" do
      turn = create(:chat_turn, chat_session: chat_session,
        metadata: { "expected_long_running_until" => 5.minutes.from_now.iso8601 })

      expect(turn.expected_long_running?).to be(true)
    end

    it "is false when the checkpoint is missing or expired" do
      turn = create(:chat_turn, chat_session: chat_session,
        metadata: { "expected_long_running_until" => 1.minute.ago.iso8601 })

      expect(turn.expected_long_running?).to be(false)
    end
  end
end
