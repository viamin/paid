# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:message) { create(:chat_message, chat_session:, role: "user") }
  let(:now) { Time.zone.parse("2026-10-27 16:00:00") }

  def create_turn(last_activity_at: 11.minutes.ago, **attributes)
    ChatTurn.create!({
      account:,
      chat_session:,
      initiating_message: message,
      status: "streaming",
      last_activity_at:
    }.merge(attributes))
  end

  it "marks an inactive unfinished turn stalled and persists an actionable transcript notice" do
    turn = create_turn(last_activity_at: now - 11.minutes)

    expect(described_class.call(now:)).to eq(1)

    expect(turn.reload).to have_attributes(status: "stalled", stalled_at: now)
    expect(turn.events.find_by(event_type: "stalled")).to be_present
    notice = chat_session.messages.find_by(metadata: { "chat_turn_stalled" => true, "chat_turn_id" => turn.id, "side_effecting_tools_completed" => false })
    expect(notice.content).to include("stopped before a durable conclusion")
  end

  it "does not stall a turn waiting for explicit tool confirmation" do
    turn = create_turn(last_activity_at: now - 11.minutes)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    expect(described_class.call(now:)).to eq(0)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a known rate-limit pause" do
    turn = create_turn(last_activity_at: now - 11.minutes)
    chat_session.update!(rate_limited_until: now + 5.minutes)

    expect(described_class.call(now:)).to eq(0)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not reclassify terminal turns" do
    turn = create_turn(status: "failed", last_activity_at: now - 11.minutes)

    expect(described_class.call(now:)).to eq(0)
    expect(turn.reload.status).to eq("failed")
  end
end
