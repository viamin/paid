# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurn do
  # @spec CHAT-TURN-LIFECYCLE-001
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user", content: "Continue") }

  it "marks a turn with no terminal outcome as stalled and preserves a visible notice" do
    turn = ChatTurn.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      status: "streaming", last_activity_at: 16.minutes.ago)

    expect(described_class.call(chat_turn: turn)).to be(true)

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "no_durable_activity")
    notice = chat_session.messages.find(&:stalled_turn_notice?)
    expect(notice.content).to include("no completion was recorded")
  end

  it "does not stall a turn awaiting a write-tool confirmation" do
    # @spec CHAT-TURN-LIFECYCLE-002
    turn = ChatTurn.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      status: "streaming", last_activity_at: 16.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    expect(described_class.call(chat_turn: turn)).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not overwrite a terminal outcome" do
    # @spec CHAT-TURN-LIFECYCLE-003
    turn = ChatTurn.create!(chat_session:, user_message:, stream_message_id: SecureRandom.uuid,
      status: "completed", completed_at: 16.minutes.ago, last_activity_at: 16.minutes.ago)

    expect(described_class.call(chat_turn: turn)).to be(false)
    expect(turn.reload.status).to eq("completed")
  end
end
