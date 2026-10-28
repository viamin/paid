# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::ClassifyStalled do
  # @spec CHAT-API-028 CHAT-API-029 CHAT-API-032
  it "atomically stalls an inactive turn and preserves an actionable notice" do
    turn = create(:chat_turn, :with_user_message, status: "streaming", last_activity_at: 31.minutes.ago)
    create(:chat_message, :tool, chat_session: turn.chat_session, tool_name: "search_code",
      created_at: 30.minutes.ago)

    expect { described_class.call(turn:) }.to change { turn.reload.status }.from("streaming").to("stalled")

    notice = turn.reload.notice_message
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "side_effecting_tools_completed" => false)
    expect(turn).to have_attributes(stall_classification: "inactivity_timeout", stalled_at: be_present)
  end

  # @spec CHAT-API-028
  it "does not reclassify a turn whose activity advanced after selection" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 5.minutes.ago)

    expect(described_class.call(turn:, cutoff: 30.minutes.ago)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end
end
