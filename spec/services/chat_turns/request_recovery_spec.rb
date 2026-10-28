# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::RequestRecovery do
  # @spec CHAT-API-030 CHAT-API-031 CHAT-API-032
  it "claims one revision-aware recovery and records the actor" do
    turn = create(:chat_turn, :with_user_message, status: "stalled")

    result = described_class.call(turn:, actor: turn.chat_session.created_by,
      expected_revision: turn.lock_version)

    expect(result).to be_success
    expect(turn.reload).to have_attributes(status: "pending", recovery_attempts: 1,
      recovery_requested_by: turn.chat_session.created_by)
    expect(ChatTurns::RecoverJob).to have_been_enqueued.with(chat_turn_id: turn.id)
  end

  # @spec CHAT-API-030
  it "deduplicates repeated and stale recovery requests" do
    turn = create(:chat_turn, :with_user_message, status: "stalled")
    revision = turn.lock_version

    first = described_class.call(turn:, actor: turn.chat_session.created_by, expected_revision: revision)
    second = described_class.call(turn:, actor: turn.chat_session.created_by, expected_revision: revision)

    expect(first).to be_success
    expect(second).not_to be_success
    expect(turn.reload.recovery_attempts).to eq(1)
    expect(turn.audit_events.last).to include("event" => "recovery_deduplicated")
  end
end
