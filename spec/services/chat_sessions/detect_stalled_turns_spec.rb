# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  let(:account) { create(:account) }
  let(:chat_session) { create(:chat_session, account:) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user", content: "Deploy this") }

  # @spec CHAT-API-027
  it "marks an inactive streaming turn stalled and creates one durable notice" do
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, last_activity_at: 11.minutes.ago)

    expect { described_class.call(turn:) }.to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to be_stalled
    notice = chat_session.messages.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "user_message_id" => user_message.id)

    expect { described_class.call(turn:) }.not_to change { chat_session.messages.where(role: "system").count }
  end

  it "does not classify a turn awaiting a tool confirmation" do
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    described_class.call(turn:)

    expect(turn.reload).to be_streaming
  end

  it "does not classify a recorded rate-limit pause" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, last_activity_at: 11.minutes.ago)

    described_class.call(turn:)

    expect(turn.reload).to be_streaming
  end
end
