# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Start do
  # @spec CHAT-TURN-RECOVERY-001
  it "creates one streaming turn for repeated delivery of the same stream id" do
    session = create(:chat_session)
    stream_message_id = SecureRandom.uuid
    user_message = create(:chat_message, chat_session: session)

    first = described_class.call(chat_session: session, stream_message_id:, user_message:)
    second = described_class.call(chat_session: session, stream_message_id:, user_message:)

    expect(first).to eq(second)
    expect(first).to have_attributes(status: "streaming", stream_message_id:)
    expect(session.chat_turns.count).to eq(1)
  end
end
