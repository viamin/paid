# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-API-027
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 16.minutes.ago)

    expect { described_class.call(now: Time.current, threshold: 15.minutes) }
      .to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to be_stalled
    expect(turn.events.order(:id).last.event_type).to eq("stalled")
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn paused for confirmation" do
    turn = create(:chat_turn, chat_session:, state: "pending", last_activity_at: 1.hour.ago)

    described_class.call(now: Time.current, threshold: 15.minutes)

    expect(turn.reload).to be_pending
    expect(chat_session.messages.where(role: "system")).to be_empty
  end

  it "does not duplicate a concurrent detector's notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 16.minutes.ago)

    2.times { described_class.call(now: Time.current, threshold: 15.minutes) }

    expect(turn.reload.events.where(event_type: "stalled").count).to eq(1)
    expect(chat_session.messages.count(&:stalled_turn_notice?)).to eq(1)
  end
end
