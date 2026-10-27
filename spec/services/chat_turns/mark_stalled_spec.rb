# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::MarkStalled do
  # @spec CHAT-TURN-002 CHAT-TURN-003 CHAT-TURN-005
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:) }
  let(:turn) { create(:chat_turn, chat_session:, user_message:, last_activity_at: 11.minutes.ago) }

  it "marks an inactive streaming turn stalled and writes an actionable notice" do
    expect(described_class.call(chat_turn: turn)).to be(true)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    notice = chat_session.messages.find_by(metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id,
      "side_effecting_tools_completed" => false })
    expect(notice.content).to include("No tool will be replayed automatically")
    expect(turn.events.find_by(event_type: "stalled")).to be_present
  end

  it "does not stall a turn waiting for confirmation" do
    turn
    pending = create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    expect(pending.id).to be > user_message.id
    expect(turn.pending_confirmation?).to be(true)

    expect(described_class.call(chat_turn: turn)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a rate-limited session" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)

    expect(described_class.call(chat_turn: turn)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end
end
