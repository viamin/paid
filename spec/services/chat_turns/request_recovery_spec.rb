# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::RequestRecovery do
  # @spec CHAT-TURN-004 CHAT-TURN-005
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:) }
  let(:turn) { create(:chat_turn, :stalled, chat_session:, user_message:) }

  it "claims one explicit recovery and enqueues it once" do
    expect { described_class.call(chat_turn: turn, actor: user) }
      .to have_enqueued_job(ChatSessions::ResumeTurnJob).with(chat_turn_id: turn.id, actor_id: user.id)

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
    expect(turn.events.find_by(event_type: "recovery_requested")).to be_present
  end

  it "rejects a repeated recovery request" do
    described_class.call(chat_turn: turn, actor: user)

    expect { described_class.call(chat_turn: turn, actor: user) }
      .to raise_error(ChatTurns::RecoveryConflictError, /no longer awaiting recovery/)

    expect(turn.events.find_by(event_type: "recovery_deduplicated")).to be_present
  end
end
