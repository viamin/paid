# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurn do
  # @spec CHAT-API-027
  let(:session) { create(:chat_session) }
  let(:message) { create(:chat_message, chat_session: session) }

  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = ChatTurn.create!(chat_session: session, initiating_message: message, state: "streaming", last_activity_at: 11.minutes.ago)

    notice = described_class.call(chat_turn: turn)

    expect(turn.reload).to have_attributes(state: "stalled", stalled_at: be_present)
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("tool results above were preserved")
  end

  it "does not stall a turn awaiting explicit confirmation" do
    turn = ChatTurn.create!(chat_session: session, initiating_message: message, state: "streaming", last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect(described_class.call(chat_turn: turn)).to eq(turn)
    expect(turn.reload.state).to eq("streaming")
  end
end
