# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  let(:chat_session) { create(:chat_session) }

  # @spec CHAT-TURN-RECOVERY-002
  it "marks an inactive partial turn stalled and preserves a durable transcript notice" do
    user_message = create(:chat_message, chat_session:, metadata: { "stream_message_id" => "stream-1" })
    turn = ChatTurn.create!(chat_session:, user_message:, status: "streaming", last_activity_at: 20.minutes.ago)
    tool_message = create(:chat_message, :tool_call, chat_session:)
    tool_message.update!(chat_turn: turn)

    expect { described_class.call(now: Time.current) }
      .to change { ChatMessage.where(chat_session:, role: "system").count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "durable_activity_timeout")
    expect(turn.metadata).to include("tool_message_ids" => [ tool_message.id ], "side_effecting_tools_completed" => false)
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "does not stall a turn waiting for confirmation" do
    user_message = create(:chat_message, chat_session:)
    turn = ChatTurn.create!(chat_session:, user_message:, status: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending", chat_turn: turn)

    described_class.call(now: Time.current)

    expect(turn.reload.status).to eq("streaming")
  end
end
