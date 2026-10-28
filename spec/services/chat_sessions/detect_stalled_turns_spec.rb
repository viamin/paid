# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  it "marks a turn with no durable conclusion as stalled and preserves an actionable notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session, role: "user")
    turn = create(:chat_turn, chat_session: session, user_message:, last_activity_at: 16.minutes.ago)

    expect { described_class.call }.to change { session.messages.where(role: "system").count }.by(1)

    notice = session.messages.system.last
    expect(turn.reload.state).to eq("stalled")
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("stopped without a saved final response")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "user_message_id" => user_message.id)
  end

  # @spec CHAT-TURN-RECOVERY-001
  it "does not stall a turn awaiting explicit tool confirmation" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session, role: "user")
    turn = create(:chat_turn, chat_session: session, user_message:, last_activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect { described_class.call }.not_to change { session.messages.system.count }

    expect(turn.reload.state).to eq("streaming")
  end
end
