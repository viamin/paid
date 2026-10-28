# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurnStallSweepJob do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-007
  it "classifies a stale turn and persists one evidence-aware notice" do
    turn = create(:chat_turn, last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool, chat_session: turn.chat_session, chat_turn: turn,
      tool_name: "request_issue_continuation", tool_result: { id: 42 })

    described_class.perform_now(now: Time.current, threshold: 15.minutes)
    described_class.perform_now(now: Time.current, threshold: 15.minutes)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "activity_timeout",
      side_effects_completed: true)
    notice = turn.messages.system.find_by("metadata ->> 'stalled_turn_notice' = 'true'")
    expect(notice.content).to include("may have completed", "Resume")
    expect(turn.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end
end
