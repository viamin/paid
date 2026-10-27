# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-002 CHAT-TURN-003
  it "marks an inactive streaming turn stalled and preserves a durable notice" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "inactivity", stalled_at: be_present)
    notice = turn.chat_session.messages.find_by(metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id })
    expect(notice).to be_present
    expect(notice.content).to include("No tool call will be repeated automatically")
  end

  it "does not stall a turn waiting for explicit tool confirmation" do
    turn = create(:chat_turn, status: "awaiting_confirmation", last_activity_at: 1.hour.ago)

    described_class.call

    expect(turn.reload.status).to eq("awaiting_confirmation")
    expect(turn.chat_session.messages.where(role: "system")).to be_empty
  end
end
