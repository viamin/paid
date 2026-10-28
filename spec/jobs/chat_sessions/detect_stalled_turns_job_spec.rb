# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  let(:session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session: session) }

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = ChatTurn.create!(chat_session: session, user_message:, status: "streaming", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago)
    pending = create(:chat_message, :tool_call, chat_session: session, chat_turn: turn, tool_status: "pending")

    described_class.perform_now(now: Time.current)

    notice = session.messages.find_by!(chat_turn: turn, role: "system")
    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "inactivity", stalled_at: be_present)
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("needs attention", "1 confirmation")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "pending_confirmation_message_ids" => [ pending.id ])
  end

  it "does not stall a confirmation pause" do
    turn = ChatTurn.create!(chat_session: session, user_message:, status: "awaiting_confirmation", started_at: 20.minutes.ago, last_activity_at: 20.minutes.ago)

    described_class.perform_now(now: Time.current)

    expect(turn.reload.status).to eq("awaiting_confirmation")
  end
end
