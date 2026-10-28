# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat turn recovery" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:chat_session) { create(:chat_session, account: user.account, created_by: user) }
  let(:turn) do
    create(:chat_turn, account: user.account, chat_session:, initiated_by: user,
      status: "stalled", detected_stalled_at: Time.current)
  end

  before do
    message = create(:chat_message, chat_session:, chat_turn: turn, content: "Continue",
      metadata: { "stream_message_id" => turn.stream_message_id })
    turn.update!(user_message: message)
    sign_in user
  end

  # @spec CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006
  it "authorizes and queues a revision-bound resume" do
    expect {
      post resume_chat_session_chat_turn_path(chat_session, turn),
        params: { expected_revision: turn.lock_version }
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).once

    expect(response).to redirect_to(chat_session_path(chat_session))
    expect(turn.reload.status).to eq("pending")
  end

  # @spec CHAT-TURN-RECOVERY-005
  it "does not resume a stale revision" do
    post resume_chat_session_chat_turn_path(chat_session, turn),
      params: { expected_revision: turn.lock_version - 1 }

    expect(response).to redirect_to(chat_session_path(chat_session))
    expect(turn.reload.status).to eq("stalled")
    expect(enqueued_jobs).to be_empty
  end
end
