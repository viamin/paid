# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  let(:session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session: session) }
  let(:turn) { create(:chat_turn, chat_session: session, user_message:, status: "streaming", last_activity_at: 11.minutes.ago) }

  it "marks an inactive partial turn stalled and preserves an actionable transcript notice" do
    expect(described_class.call(turn:)).to be(true)

    expect(turn.reload).to have_attributes(status: "stalled", detected_stalled_at: be_present)
    notice = session.messages.find_by(chat_turn: turn, role: "system")
    expect(notice).to be_chat_turn_stalled_notice
    expect(notice.content).to include("no final assistant response")
    expect(turn.events.last).to have_attributes(event_type: "stalled")
  end

  it "does not classify a pending confirmation as stalled" do
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect(described_class.call(turn:)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not classify a known rate-limit pause as stalled" do
    session.update!(rate_limited_until: 5.minutes.from_now)

    expect(described_class.call(turn:)).to be(false)
  end
end
