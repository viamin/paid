# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
  it "marks inactive streaming turns stalled and persists an actionable transcript notice" do
    turn = create(:chat_turn, :streaming, last_activity_at: 20.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to have_attributes(status: "stalled", classification: "durable_activity_timeout")
    notice = turn.chat_session.messages.order(:id).last
    expect(notice).to have_attributes(role: "system", chat_turn: turn)
    expect(notice.metadata).to include("stalled_turn_notice" => true, "turn_id" => turn.id)
  end

  it "leaves pending confirmation turns untouched" do
    turn = create(:chat_turn, :awaiting_confirmation, last_activity_at: 20.minutes.ago)

    described_class.perform_now

    expect(turn.reload.status).to eq("awaiting_confirmation")
  end
end
