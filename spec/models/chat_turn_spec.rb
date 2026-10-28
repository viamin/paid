# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  it "has a durable lifecycle and does not treat stalled as successful" do
    # @spec CHAT-TURN-STALL-001
    turn = create(:chat_turn, :streaming)

    turn.stall!

    expect(turn.reload.status).to eq("stalled")
    expect(turn.status).not_to eq("completed")
  end

  it "keeps awaiting confirmation terminal and distinguishable from a stall" do
    # @spec CHAT-TURN-STALL-002
    turn = create(:chat_turn, :awaiting_confirmation)

    expect(turn).to be_terminal
    expect(turn.status).not_to eq("stalled")
  end
end
