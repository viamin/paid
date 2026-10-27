# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::StallSweepJob do
  # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  it "stalls inactive streaming turns but preserves pending confirmations" do
    stalled = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)
    pending_session = create(:chat_session, account:, created_by: user)
    pending = create(:chat_turn, chat_session: pending_session, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: pending_session, tool_status: "pending")

    described_class.perform_now

    expect(stalled.reload.status).to eq("stalled")
    expect(pending.reload.status).to eq("streaming")
  end
end
