# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::StallDetector do
  # @spec CHAT-TURN-002
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and persists an explanatory transcript notice" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(state: "stalled", stalled_at: be_present)
    expect(turn.messages.find_by(role: "system")).to have_attributes(
      content: include("stopped before a final answer"),
      metadata: include("stalled_turn_notice" => true)
    )
  end

  it "does not stall a turn waiting for a tool confirmation" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, chat_turn: turn, tool_status: "pending")

    described_class.call

    expect(turn.reload.state).to eq("streaming")
  end
end
