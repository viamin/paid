# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RecoverStalledTurn do
  # @spec CHAT-TURN-004 CHAT-TURN-005 CHAT-TURN-006
  it "claims one safe recovery and enqueues from the durable user checkpoint" do
    turn = create(:chat_turn, status: "stalled", classification: "infrastructure_failure")

    expect {
      described_class.call(turn: turn, actor: turn.chat_session.created_by, expected_revision: turn.lock_version)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).with(
      chat_session_id: turn.chat_session_id,
      content: turn.user_message.content,
      stream_message_id: turn.stream_message_id,
      actor_id: turn.chat_session.created_by_id
    )

    expect(turn.reload).to have_attributes(status: "pending", recovery_attempts: 1)
  end

  it "refuses to replay a turn after tool activity" do
    turn = create(:chat_turn, status: "stalled")
    create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "approved")

    expect {
      described_class.call(turn: turn, actor: turn.chat_session.created_by, expected_revision: turn.lock_version)
    }.to raise_error(ChatSessions::RecoverStalledTurn::ConfirmationRequired)
  end

  it "rejects a repeated recovery claim" do
    turn = create(:chat_turn, status: "stalled")

    described_class.call(turn: turn, actor: turn.chat_session.created_by, expected_revision: turn.lock_version)

    expect {
      described_class.call(turn: turn.reload, actor: turn.chat_session.created_by, expected_revision: turn.lock_version)
    }.to raise_error(ChatSessions::RecoverStalledTurn::Conflict, /not awaiting/)
  end
end
