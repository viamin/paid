# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RetryStalledTurn do
  # @spec CHAT-TURN-RECOVERY-004
  it "queues one explicit retry and rejects a repeated request" do
    turn = create(:chat_turn, status: "stalled")
    actor = turn.chat_session.created_by

    expect {
      described_class.call(chat_turn: turn, actor:, lock_version: turn.lock_version)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect {
      described_class.call(chat_turn: turn.reload, actor:, lock_version: 0)
    }.to raise_error(ActiveRecord::StaleObjectError)
    expect(turn.events.where(event_type: "recovery_requested").count).to eq(1)
  end
end
