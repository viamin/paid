# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  let(:now) { Time.zone.parse("2026-10-28 12:00:00") }
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.before(now))

    expect(described_class.call(now:)).to contain_exactly(turn)

    expect(turn.reload).to have_attributes(status: "stalled", detected_stalled_at: now)
    notice = chat_session.messages.order(:id).last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("remaining response is unknown")
  end

  it "does not mark a turn stalled while a write confirmation is pending" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.before(now))
    create(:chat_message, chat_session:, role: "assistant", content: nil, tool_name: "create_issue",
      tool_call_id: "call_1", tool_status: "pending")

    expect(described_class.call(now:)).to be_empty
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not mark a leased long-running operation stalled" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.before(now),
      metadata: { "expected_completion_at" => 1.hour.after(now).iso8601 })

    expect(described_class.call(now:)).to be_empty
    expect(turn.reload.status).to eq("streaming")
  end

  it "deduplicates repeated detection" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.before(now))

    2.times { described_class.call(now:) }

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end
end
