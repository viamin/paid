# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-026
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user", content: "Investigate this") }

  it "marks a quiet streaming turn stalled and persists an actionable notice" do
    turn = ChatTurn.create!(chat_session:, user_message:, actor: user, status: "streaming", last_activity_at: 10.minutes.ago)

    expect { described_class.call(now: Time.current) }
      .to change { turn.reload.status }.from("streaming").to("stalled")
      .and change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.events.last.event_type).to eq("stalled")
    expect(chat_session.messages.last.metadata).to include("stalled_turn_notice" => true, "chat_turn_id" => turn.id)
  end

  it "does not stall a turn waiting for user confirmation" do
    turn = ChatTurn.create!(chat_session:, user_message:, actor: user, status: "pending_confirmation", last_activity_at: 10.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload.status).to eq("pending_confirmation")
  end
end
