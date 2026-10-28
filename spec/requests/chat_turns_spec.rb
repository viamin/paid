# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ChatTurns" do
  # @spec CHAT-API-029
  let(:user) { create(:user) }
  let(:session) { create(:chat_session, account: user.account, created_by: user) }
  let(:message) { create(:chat_message, chat_session: session, role: "user", content: "Continue") }
  let(:turn) do
    create(:chat_turn, account: user.account, chat_session: session, user_message: message, status: "stalled")
  end

  it "requires authentication" do
    post resume_chat_session_chat_turn_path(session, turn), params: { revision: turn.lock_version }

    expect(response).to redirect_to(new_user_session_path)
  end

  it "queues one revision-aware recovery for an authorized user" do
    sign_in user

    expect {
      post resume_chat_session_chat_turn_path(session, turn), params: { revision: turn.lock_version }
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(response).to redirect_to(chat_session_path(session))
  end

  it "does not expose another account's stalled turn" do
    sign_in create(:user)

    post resume_chat_session_chat_turn_path(session, turn), params: { revision: turn.lock_version }

    expect(response).to have_http_status(:not_found)
  end
end
