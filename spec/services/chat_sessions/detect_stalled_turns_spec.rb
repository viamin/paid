# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
  it "marks an inactive streaming turn stalled and appends one notice" do
    session = create(:chat_session)
    message = create(:chat_message, chat_session: session)
    turn = ChatTurn.create!(chat_session: session, user_message: message, state: "streaming", last_activity_at: 16.minutes.ago)

    expect { described_class.call(now: Time.current) }.to change { session.messages.system.count }.by(1)
    expect(turn.reload).to have_attributes(state: "stalled", classification: "no_durable_activity")
    expect { described_class.call(now: Time.current) }.not_to change { session.messages.system.count }
  end

  # @spec CHAT-TURN-RECOVERY-002
  it "keeps confirmation and rate-limit waits out of the stalled state" do
    session = create(:chat_session, rate_limited_until: 1.hour.from_now)
    message = create(:chat_message, chat_session: session)
    ChatTurn.create!(chat_session: session, user_message: message, state: "streaming", last_activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    described_class.call(now: Time.current)

    expect(ChatTurn.last).to be_streaming
  end
end
