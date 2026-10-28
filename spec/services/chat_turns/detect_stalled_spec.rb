# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  it "marks an inactive streaming turn stalled and preserves a transcript notice" do
    turn = create(:chat_turn, :streaming, chat_session:, last_activity_at: 11.minutes.ago)

    expect { described_class.call }.to change { chat_session.messages.system.count }.by(1)

    expect(turn.reload).to be_stalled
    expect(turn.detected_at).to be_present
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn awaiting a tool confirmation" do
    turn = create(:chat_turn, :streaming, chat_session:, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    described_class.call

    expect(turn.reload).to be_streaming
  end

  it "does not stall a turn paused for a provider rate limit" do
    chat_session.update!(rate_limited_until: 1.hour.from_now)
    turn = create(:chat_turn, :streaming, chat_session:, last_activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload).to be_streaming
  end
end
