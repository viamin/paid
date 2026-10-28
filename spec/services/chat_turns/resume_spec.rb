# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Resume do
  include ActiveJob::TestHelper

  # @spec CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006
  it "queues one checkpoint recovery for a stalled revision" do
    turn = create(:chat_turn, status: "stalled", detected_stalled_at: Time.current)
    user_message = create(:chat_message, chat_session: turn.chat_session, chat_turn: turn,
      content: "Deploy it", metadata: { "stream_message_id" => turn.stream_message_id })
    turn.update!(user_message: user_message)
    revision = turn.lock_version

    first = described_class.call(chat_turn: turn, actor: turn.initiated_by, expected_revision: revision)
    second = described_class.call(chat_turn: turn.reload, actor: turn.initiated_by, expected_revision: revision)

    expect(first).to eq(second)
    expect(first.reload.duplicate_prevention_count).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == ChatSessions::ProcessMessageJob }).to eq(1)
    expect(turn.chat_session.messages.where(role: "user").count).to eq(1)
  end
end
