# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  include ActiveSupport::Testing::TimeHelpers

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "marks inactive work stalled and persists one actionable notice" do
    turn = create(:chat_turn, last_activity_at: 31.minutes.ago, last_checkpoint_message: nil)

    expect { described_class.call(turn:) }.to change { turn.reload.state }.from("streaming").to("stalled")
      .and change { turn.chat_session.messages.where("metadata ->> 'chat_turn_stalled_notice' = 'true'").count }.by(1)

    notice = turn.chat_session.messages.order(:id).last
    expect(notice.content).to include("remaining work is unknown", "Resume")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "turn_revision" => 1)

    expect { described_class.call(turn:) }.not_to change(ChatMessage, :count)
  end

  # @spec CHAT-TURN-RECOVERY-002
  it "does not classify an active lease or pending confirmation as stalled" do
    leased = create(:chat_turn, last_activity_at: 31.minutes.ago, lease_expires_at: 10.minutes.from_now)
    awaiting = create(:chat_turn, last_activity_at: 31.minutes.ago, pause_reason: "confirmation")
    create(:chat_message, :tool_call, chat_session: awaiting.chat_session, tool_status: "pending")

    expect(described_class.call(turn: leased)).to be(false)
    expect(described_class.call(turn: awaiting)).to be(false)
    expect(leased.reload).to be_streaming
    expect(awaiting.reload).to be_streaming
  end
end
