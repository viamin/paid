# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResumeStalledTurn do
  # @spec CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006
  it "claims one explicit recovery and enqueues from the original durable user checkpoint" do
    turn = create(:chat_turn, status: "stalled")

    expect { described_class.call(chat_turn: turn, actor: turn.chat_session.created_by) }
      .to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
    expect { described_class.call(chat_turn: turn, actor: turn.chat_session.created_by) }
      .to raise_error(ChatSessions::ResumeStalledTurn::RecoveryConflictError)
  end
end
