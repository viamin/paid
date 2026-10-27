# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-001, CHAT-TURN-002
  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    turn = ChatTurn.create!(chat_session: session, user_message:, status: "streaming", last_activity_at: 11.minutes.ago)

    expect(described_class.call).to eq(1)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    expect(turn.detected_at).to be_present
    notice = session.messages.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("stopped before a final response")
  end

  it "does not stall a turn waiting for tool confirmation" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    ChatTurn.create!(chat_session: session, user_message:, status: "pending", last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect(described_class.call).to eq(0)
    expect(session.messages.where(role: "system", metadata: { "stalled_turn_notice" => true })).to be_empty
  end
end
