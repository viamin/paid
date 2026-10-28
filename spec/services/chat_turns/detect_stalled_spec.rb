# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-028
  let(:turn) { create(:chat_turn, last_activity_at: 31.minutes.ago) }

  it "marks an inactive turn stalled and persists one actionable notice" do
    expect { described_class.call(turn: turn, now: Time.current) }
      .to change { turn.chat_session.messages.where("metadata ->> 'stalled_turn_id' = ?", turn.id.to_s).count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", stall_classification: "ambiguous_stop")
    expect(turn.detected_at).to be_present
  end

  it "does not stall a turn awaiting confirmation" do
    turn.update!(metadata: { "awaiting_confirmation" => true })

    expect(described_class.call(turn: turn, now: Time.current)).to be false
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a rate-limited session" do
    turn.chat_session.update!(rate_limited_until: 10.minutes.from_now)

    expect(described_class.call(turn: turn, now: Time.current)).to be false
  end

  it "uses the longer threshold for a tool operation with no durable result" do
    tool_call = create(:chat_message, :tool_call, chat_session: turn.chat_session,
      tool_call_id: "call-running")
    turn.update!(checkpoint_message: tool_call)

    expect(described_class.call(turn: turn, now: Time.current)).to be false
  end

  it "deduplicates repeated classifications" do
    described_class.call(turn: turn, now: Time.current)

    expect(described_class.call(turn: turn.reload, now: Time.current)).to be false
  end
end
