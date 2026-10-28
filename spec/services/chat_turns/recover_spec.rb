# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Recover do
  let(:turn) { create(:chat_turn, state: "stalled", detected_stalled_at: Time.current) }
  let(:actor) { turn.chat_session.created_by }

  # @spec CHAT-TURN-RECOVERY-004
  it "requires confirmation for an ambiguous stalled turn" do
    expect {
      described_class.call(turn:, actor:, revision: turn.revision, confirmed: false)
    }.to raise_error(ChatTurns::RecoveryConfirmationRequired)
  end

  # @spec CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-006
  it "dispatches one checkpoint resume and deduplicates a repeated request" do
    expect {
      first = described_class.call(turn:, actor:, revision: turn.revision, confirmed: true)
      second = described_class.call(turn:, actor:, revision: turn.revision, confirmed: true)
      expect(second.id).to eq(first.id)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).once

    expect(turn.reload.duplicate_prevention_count).to eq(1)
    expect(turn.recovery_attempts.count).to eq(1)
  end

  # @spec CHAT-TURN-RECOVERY-004
  it "rejects a stale revision" do
    expect {
      described_class.call(turn:, actor:, revision: turn.revision + 1, confirmed: true)
    }.to raise_error(ChatTurns::StaleRevision)
  end
end
