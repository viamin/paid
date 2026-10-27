# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Resume do
  # @spec CHAT-TURN-003
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: actor) }
  let(:user_message) { create(:chat_message, chat_session: chat_session, role: "user", content: "continue") }
  let(:turn) { ChatTurn.create!(chat_session: chat_session, user_message: user_message, status: "stalled", activity_at: 11.minutes.ago) }

  it "claims one recovery and queues work from the persisted checkpoint" do
    expect { described_class.call(turn:, actor: actor) }
      .to have_enqueued_job(ChatSessions::ProcessMessageJob)
      .with(hash_including(chat_session_id: chat_session.id, chat_turn_id: turn.id, content: "continue"))

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
  end

  it "rejects a repeated recovery request" do
    described_class.call(turn:, actor: actor)

    expect { described_class.call(turn:, actor: actor) }
      .to raise_error(ChatTurns::Resume::ConflictError, "This turn is no longer stalled")
  end
end
