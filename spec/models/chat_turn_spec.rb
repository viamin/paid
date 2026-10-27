# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn, type: :model do
  # @spec CHAT-TURN-RECOVERY-001
  it "requires a valid lifecycle status" do
    turn = build(:chat_turn, status: "unknown")

    expect(turn).not_to be_valid
    expect(turn.errors[:status]).to include("is not included in the list")
  end
end
