# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RetryStalledTurn do
  # @spec CHAT-API-027
  it "claims a stalled turn once before queueing its explicit retry" do
    actor = create(:user)
    session = create(:chat_session, account: actor.account, created_by: actor)
    request = create(:chat_message, chat_session: session, role: "user", content: "Deploy this")
    turn = create(:chat_turn, chat_session: session, user_message: request, status: "stalled")

    expect {
      expect(described_class.call(turn:, actor:)).to be(true)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).with(
      hash_including(chat_session_id: session.id, actor_id: actor.id, content: "Deploy this")
    )
    expect(turn.reload.status).to eq("abandoned")
    expect(described_class.call(turn:, actor:)).to be(false)
  end
end
