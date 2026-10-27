# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-001 CHAT-TURN-002 CHAT-TURN-003
  let(:session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload).to be_stalled
    notice = session.messages.system.last
    expect(notice.content).to include("stalled")
    expect(notice.metadata).to include("chat_turn_stalled" => true, "chat_turn_id" => turn.id)
  end

  it "does not stall a turn awaiting a tool confirmation" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    described_class.call(now: Time.current)

    expect(turn.reload).to be_streaming
    expect(session.messages.system.where("metadata ->> 'chat_turn_stalled' = 'true'")).to be_empty
  end

  it "does not stall a rate-limited session awaiting its known recovery window" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)
    session.update!(rate_limited_until: 5.minutes.from_now)

    described_class.call(now: Time.current)

    expect(turn.reload).to be_streaming
  end
end
