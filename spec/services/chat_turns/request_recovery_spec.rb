# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::RequestRecovery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:) }
  let(:turn) { create(:chat_turn, chat_session:, user_message:, state: "stalled", classification: "ambiguous_model_stop") }

  # @spec CHAT-TURN-RECOVERY-009 CHAT-TURN-RECOVERY-011 CHAT-TURN-RECOVERY-013
  it "deduplicates repeated authorized recovery requests and audits the prevented duplicate" do
    expect {
      first = described_class.call(turn: turn, actor: user, source: :user)
      second = described_class.call(turn: turn.reload, actor: user, source: :user)

      expect(first.status).to eq("started")
      expect(second.status).to eq("duplicate")
    }.to have_enqueued_job(ChatTurns::RecoverTurnJob).once

    expect(turn.reload.recovery_state).to eq("requested")
    expect(turn.events.duplicate_prevented.count).to eq(1)
  end
end
