# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  let(:session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session: session) }

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "finds only inactive pending and streaming turns" do
    stale = described_class.create!(chat_session: session, user_message:, status: "streaming", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago)
    confirmation = described_class.create!(chat_session: session, user_message: create(:chat_message, chat_session: session), status: "awaiting_confirmation", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago)
    active = described_class.create!(chat_session: session, user_message: create(:chat_message, chat_session: session), status: "streaming", started_at: Time.current, last_activity_at: Time.current)

    expect(described_class.stalled_before(15.minutes.ago)).to contain_exactly(stale)
    expect(described_class.stalled_before(15.minutes.ago)).not_to include(confirmation, active)
  end

  # @spec CHAT-TURN-RECOVERY-004
  it "records a recovery request once without changing a stalled turn's outcome" do
    turn = described_class.create!(chat_session: session, user_message:, status: "stalled", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago, stalled_at: 5.minutes.ago)

    expect(turn.request_recovery!).to be true
    expect(turn.request_recovery!).to be false
    expect(turn.reload).to have_attributes(status: "stalled", recovery_attempts: 1, recovery_requested_at: be_present)
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "does not classify a turn refreshed after the detector selected it" do
    turn = described_class.create!(chat_session: session, user_message:, status: "streaming", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago)
    turn.record_activity!

    expect(turn.mark_stalled!(before: 15.minutes.ago)).to be false
    expect(turn.reload.status).to eq("streaming")
  end
end
