# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-001
  it "requires the user message to belong to its session" do
    turn = build(:chat_turn, chat_session: create(:chat_session), user_message: create(:chat_message))

    expect(turn).not_to be_valid
    expect(turn.errors[:user_message]).to include("must belong to the chat session")
  end
end
