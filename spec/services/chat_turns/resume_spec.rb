# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Resume do
  # @spec CHAT-API-029
  let(:user) { create(:user) }
  let(:session) { create(:chat_session, account: user.account, created_by: user, auto_approve: true) }
  let(:message) { create(:chat_message, chat_session: session, role: "user", content: "Deploy it") }
  let(:turn) do
    create(:chat_turn, account: user.account, chat_session: session, user_message: message,
      status: "stalled", recovery_attempts: 0)
  end

  it "atomically claims and enqueues a recovery from the durable message" do
    expect {
      described_class.call(turn: turn, actor: user, expected_revision: turn.lock_version)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).with(
      chat_session_id: session.id,
      actor_id: user.id,
      content: "Deploy it",
      stream_message_id: turn.stream_id,
      recovery: true
    )

    expect(turn.reload).to have_attributes(status: "pending", recovery_attempts: 1, recovered_by: user)
  end

  it "rejects a stale repeated recovery without another enqueue" do
    revision = turn.lock_version
    described_class.call(turn: turn, actor: user, expected_revision: revision)
    enqueued_count = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    expect {
      described_class.call(turn: turn.reload, actor: user, expected_revision: revision)
    }.to raise_error(ChatTurns::Resume::ConflictError)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(enqueued_count)
  end
end
