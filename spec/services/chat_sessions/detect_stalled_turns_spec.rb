# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-001 CHAT-TURN-003 CHAT-TURN-007
  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = create(:chat_turn, status: "streaming", last_activity_at: 20.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "unknown_inactivity")
    notice = turn.chat_session.messages.find(&:stalled_turn_notice?)
    expect(notice).to be_present
    expect(notice.content).to include("needs attention")
  end
end
