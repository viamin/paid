# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-TURN-RECOVERY-002
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    user_message = create(:chat_message, chat_session:, role: "user")
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", activity_at: 16.minutes.ago)

    expect { described_class.perform_now }.to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to be_stalled
    expect(turn.detection_at).to be_present
    notice = chat_session.messages.order(:id).last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("did not finish")
  end

  it "does not stall a turn awaiting a tool confirmation" do
    user_message = create(:chat_message, chat_session:, role: "user")
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", activity_at: 16.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to be_streaming
  end

  it "does not stall a known rate-limit pause" do
    user_message = create(:chat_message, chat_session:, role: "user")
    chat_session.update!(rate_limited_until: 1.hour.from_now)
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", activity_at: 16.minutes.ago)

    described_class.perform_now

    expect(turn.reload).to be_streaming
  end
end
