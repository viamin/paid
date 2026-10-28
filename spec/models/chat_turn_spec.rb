# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  it "requires a durable lifecycle status" do
    turn = build(:chat_turn, status: "unknown")

    expect(turn).not_to be_valid
    expect(turn.errors[:status]).to be_present
  end

  it "identifies a pending confirmation from durable metadata" do
    turn = build(:chat_turn, metadata: { "awaiting_confirmation" => true })

    expect(turn).to be_awaiting_confirmation
  end
end
