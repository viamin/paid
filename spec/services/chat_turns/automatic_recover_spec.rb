# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::AutomaticRecover do
  # @spec CHAT-API-027
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:stream_message_id) { SecureRandom.uuid }
  let(:user_message) do
    create(:chat_message, chat_session:, role: "user", content: "Investigate this",
      metadata: { "stream_message_id" => stream_message_id })
  end

  it "retries a single infrastructure failure with no tool activity" do
    turn = ChatTurn.create!(chat_session:, user_message:, actor: user, status: "failed",
      failure_classification: "infrastructure", last_activity_at: Time.current)

    expect {
      described_class.call(chat_session:, stream_message_id:, actor: user)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.reload.recovery_attempts).to eq(1)
    expect(turn.events.last.event_type).to eq("automatic_recovery_started")
  end

  it "does not retry when a tool result was persisted" do
    turn = ChatTurn.create!(chat_session:, user_message:, actor: user, status: "failed",
      failure_classification: "infrastructure", last_activity_at: Time.current)
    create(:chat_message, :tool, chat_session:, chat_turn: turn, content: "{}")

    expect {
      expect(described_class.call(chat_session:, stream_message_id:, actor: user)).to be(false)
    }.not_to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.events.last.event_type).to eq("automatic_recovery_prevented")
  end
end
