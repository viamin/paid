# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  # @spec CHAT-TURN-LIFECYCLE-003 CHAT-TURN-LIFECYCLE-004 CHAT-TURN-LIFECYCLE-005 CHAT-TURN-LIFECYCLE-011
  it "marks an inactive streaming turn stalled and leaves a durable transcript notice" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 16.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(status: "stalled", classification: "infrastructure_failure")
    expect(turn.chat_session.messages.find_by(chat_turn: turn)).to be_stall_notice
    expect(turn.events.stalls).to exist
  end

  it "does not stall a turn awaiting an approved write-tool confirmation" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session: turn.chat_session, chat_turn: turn, tool_status: "pending")

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
