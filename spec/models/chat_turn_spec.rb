# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-001 CHAT-TURN-002 CHAT-TURN-003 CHAT-TURN-004
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive unfinished turn stalled and persists one actionable notice" do
    turn = described_class.create!(chat_session:, stream_message_id: SecureRandom.uuid, status: "streaming",
      last_activity_at: 11.minutes.ago)

    expect(turn.mark_stalled!).to be(true)
    expect(turn.reload).to have_attributes(status: "stalled", stalled_at: be_present)
    expect(chat_session.messages.where("metadata ->> 'chat_turn_stalled_notice' = 'true'").count).to eq(1)
    expect(turn.mark_stalled!).to be(false)
  end

  it "does not classify a pending confirmation or rate-limited turn as stalled" do
    user_message = create(:chat_message, chat_session:, role: "user")
    turn = described_class.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      status: "streaming", last_activity_at: 11.minutes.ago)
    create(:chat_message, chat_session:, role: "assistant", content: nil, tool_name: "write", tool_call_id: "one", tool_status: "pending")

    expect(turn.mark_stalled!).to be(false)
    chat_session.messages.pending_tool_confirmations.update_all(tool_status: "denied")
    chat_session.update!(rate_limited_until: 5.minutes.from_now)
    expect(turn.mark_stalled!).to be(false)
  end

  it "deduplicates recovery and refuses replay after a side effect" do
    turn = described_class.create!(chat_session:, stream_message_id: SecureRandom.uuid, status: "stalled",
      last_activity_at: 11.minutes.ago)

    turn.begin_recovery!
    expect { turn.begin_recovery! }.to raise_error(ArgumentError, "Turn is not stalled")
    turn.update!(status: "stalled", recovery_started_at: nil, side_effecting_tools_completed: true)
    expect { turn.begin_recovery! }.to raise_error(ArgumentError, /requires confirmation/)
  end
end
