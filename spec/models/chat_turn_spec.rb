# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  it "tracks durable activity and terminal lifecycle state" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 10.minutes.ago)

    turn.record_activity!
    turn.complete!

    expect(turn.reload).to have_attributes(status: "completed", completed_at: be_present)
    expect(turn.last_activity_at).to be_within(1.second).of(Time.current)
  end

  # @spec CHAT-API-027 CHAT-API-028
  it "only exposes inactive executable turns as stall candidates" do
    stalled = create(:chat_turn, status: "streaming", last_activity_at: 31.minutes.ago)
    create(:chat_turn, status: "awaiting_confirmation", last_activity_at: 2.hours.ago)
    create(:chat_turn, status: "rate_limited", last_activity_at: 2.hours.ago)
    create(:chat_turn, status: "streaming", last_activity_at: 2.hours.ago, lease_expires_at: 1.hour.from_now)

    expect(described_class.stall_candidates(30.minutes.ago)).to contain_exactly(stalled)
  end

  # @spec CHAT-API-031
  it "only permits bounded automatic recovery for an opted-in safe infrastructure checkpoint" do
    turn = build(:chat_turn, failure_classification: "infrastructure_failure",
      checkpoint_replay_safe: true, side_effecting_tools_completed: false)

    expect(turn).to be_automatically_recoverable

    turn.side_effecting_tools_completed = true
    expect(turn).not_to be_automatically_recoverable
  end
end
