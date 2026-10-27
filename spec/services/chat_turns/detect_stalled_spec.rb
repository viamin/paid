# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-002, CHAT-TURN-003
  it "marks an inactive active turn stalled and preserves an actionable transcript notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    turn = ChatTurn.create!(chat_session: session, initiating_message: user_message, status: "streaming", activity_at: 11.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    notice = session.messages.find_by(metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id, "side_effecting_tool_completed" => false })
    expect(notice.content).to include("remaining response is unknown")
  end

  # @spec CHAT-TURN-002
  it "does not stall a turn awaiting an explicit confirmation" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")
    turn = ChatTurn.create!(chat_session: session, initiating_message: user_message, status: "streaming", activity_at: 11.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload.status).to eq("streaming")
  end
end
