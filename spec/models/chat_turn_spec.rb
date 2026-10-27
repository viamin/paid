# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  it "records the durable lifecycle for a user message" do
    message = create(:chat_message)
    turn = described_class.create!(chat_session: message.chat_session, user_message: message, last_activity_at: Time.current)

    turn.mark_streaming!
    turn.complete!

    expect(turn).to have_attributes(status: "completed", completed_at: be_present)
  end

  # @spec CHAT-API-028
  it "does not consider a pending confirmation stalled" do
    session = create(:chat_session)
    message = create(:chat_message, chat_session: session)
    turn = described_class.create!(chat_session: session, user_message: message, status: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect(turn).not_to be_stallable
  end

  # @spec CHAT-API-028
  it "does not consider a known long-running operation stalled before its deadline" do
    message = create(:chat_message)
    turn = described_class.create!(
      chat_session: message.chat_session,
      user_message: message,
      status: "streaming",
      last_activity_at: 20.minutes.ago,
      metadata: { "long_running_until" => 1.hour.from_now.iso8601 }
    )

    expect(turn).not_to be_stallable
  end
end
