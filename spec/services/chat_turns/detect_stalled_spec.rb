# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-002
  let(:chat_session) { create(:chat_session) }
  let(:turn) { create(:chat_turn, chat_session:, last_activity_at: 16.minutes.ago) }

  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    expect { described_class.call(turn:) }.to change { ChatTurnEvent.where(event_type: "stalled").count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    notice = chat_session.messages.find_by(metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "completed_tools" => [] })
    expect(notice).to be_present
    expect(notice.content).to include("automatic replay is disabled")
  end

  it "does not classify the same turn twice" do
    described_class.call(turn:)

    expect { described_class.call(turn: turn.reload) }.not_to change { ChatTurnEvent.where(event_type: "stalled").count }
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "does not stall a turn awaiting a tool confirmation" do
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    expect(described_class.call(turn:)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a known rate-limited session" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)

    expect(described_class.call(turn:)).to be(false)
  end

  it "does not stall a turn with an unexpired long-operation checkpoint" do
    turn.update!(metadata: { "stall_exempt_until" => 5.minutes.from_now.iso8601 })

    expect(described_class.call(turn:)).to be(false)
  end
end
