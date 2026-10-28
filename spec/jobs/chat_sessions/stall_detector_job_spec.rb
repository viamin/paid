# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::StallDetectorJob do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = create(:chat_turn, chat_session:, state: "streaming", last_activity_at: 11.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to have_attributes(state: "stalled", failure_classification: "no_durable_activity")
    notice = chat_session.messages.find(&:stalled_turn_notice?)
    expect(notice.content).to include("last durable activity", "unknown", "No tool is being replayed")
    expect(notice.metadata).to include("chat_turn_id" => turn.id)
  end

  it "does not stall a turn awaiting confirmation" do
    turn = create(:chat_turn, chat_session:, state: "awaiting_confirmation", last_activity_at: 11.minutes.ago)

    described_class.perform_now

    expect(turn.reload.state).to eq("awaiting_confirmation")
  end

  it "does not stall a rate-limited session" do
    chat_session.update!(rate_limited_until: 1.hour.from_now)
    turn = create(:chat_turn, chat_session:, state: "streaming", last_activity_at: 11.minutes.ago)

    described_class.perform_now

    expect(turn.reload.state).to eq("streaming")
  end

  it "does not create a second notice when the sweep repeats" do
    turn = create(:chat_turn, chat_session:, state: "streaming", last_activity_at: 11.minutes.ago)

    2.times { described_class.perform_now }

    expect(turn.reload.state).to eq("stalled")
    expect(chat_session.messages.count(&:stalled_turn_notice?)).to eq(1)
  end
end
