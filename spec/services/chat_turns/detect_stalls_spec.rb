# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  # @spec CHAT-TURN-001 CHAT-TURN-002
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session: chat_session, role: "user") }

  it "marks an inactive streaming turn stalled and preserves a durable notice" do
    turn = ChatTurn.create!(chat_session: chat_session, user_message: user_message, status: "streaming", activity_at: 11.minutes.ago)

    expect { described_class.call }.to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn waiting for an explicit tool confirmation" do
    turn = ChatTurn.create!(chat_session: chat_session, user_message: user_message, status: "streaming", activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: chat_session, tool_status: "pending")

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end

  it "does not duplicate a notice when competing sweeps inspect the same turn" do
    turn = ChatTurn.create!(chat_session: chat_session, user_message: user_message, status: "streaming", activity_at: 11.minutes.ago)

    2.times { described_class.call }

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end
end
