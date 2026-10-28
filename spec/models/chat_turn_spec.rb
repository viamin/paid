# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  it "records a streaming turn for a user message" do
    message = create(:chat_message)
    turn = described_class.start_for!(chat_session: message.chat_session, user_message: message)

    expect(turn.lifecycle).to eq("streaming")
    expect(turn.last_activity_at).to be_present
  end

  it "allows only one durable turn for each user message" do
    message = create(:chat_message)
    session = message.chat_session

    first = described_class.start_for!(chat_session: session, user_message: message)
    second = described_class.start_for!(chat_session: session, user_message: message)

    expect(second).to eq(first)
  end
end
