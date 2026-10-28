# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-027
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:) }

  around do |example|
    previous = ENV["CHAT_TURN_STALL_TIMEOUT_SECONDS"]
    ENV["CHAT_TURN_STALL_TIMEOUT_SECONDS"] = "60"
    example.run
  ensure
    ENV["CHAT_TURN_STALL_TIMEOUT_SECONDS"] = previous
  end

  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", last_activity_at: 2.minutes.ago)

    expect(described_class.call).to eq(1)

    expect(turn.reload.status).to eq("stalled")
    notice = chat_session.messages.find_by(metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "user_message_id" => user_message.id })
    expect(notice.content).to include("stopped before a final response")
  end

  it "does not mark a rate-limited turn stalled" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", last_activity_at: 2.minutes.ago)

    expect(described_class.call).to eq(0)
    expect(turn.reload.status).to eq("streaming")
  end
end
