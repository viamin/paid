# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-001 CHAT-TURN-003
  it "marks inactive streaming turns stalled and persists one actionable transcript notice" do
    turn = create(:chat_turn, :streaming, activity_at: 16.minutes.ago)

    expect { described_class.perform_now }.to change { turn.chat_session.messages.system.count }.by(1)

    expect(turn.reload.status).to eq("stalled")
    expect(turn.detection_at).to be_present
    notice = turn.chat_session.messages.system.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id)

    expect { described_class.perform_now }.not_to change { turn.chat_session.messages.count }
  end

  it "leaves a pending confirmation active" do
    turn = create(:chat_turn, :streaming, activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "pending")

    described_class.perform_now

    expect(turn.reload.status).to eq("streaming")
  end
end
