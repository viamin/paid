# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-RECOVERY-001
  it "marks an inactive turn stalled and preserves an actionable transcript notice" do
    turn = create(:chat_turn, last_activity_at: 16.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "no_durable_activity")
    expect(turn.events.where(event_type: "stalled")).to exist
    expect(turn.chat_session.messages.last).to be_stalled_turn_notice
  end

  # @spec CHAT-TURN-RECOVERY-002
  it "does not stall a turn waiting for confirmation" do
    turn = create(:chat_turn, last_activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "pending")

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
