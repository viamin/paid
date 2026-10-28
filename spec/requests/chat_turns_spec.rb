# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat turn recovery" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:turn) { create(:chat_turn, :with_user_message, account:, chat_session:, initiated_by: user, status: "stalled") }

  # @spec CHAT-API-030 CHAT-API-031
  it "requires authentication" do
    post recover_chat_session_chat_turn_path(chat_session, turn), params: { revision: turn.lock_version }

    expect(response).to redirect_to(new_user_session_path)
  end

  # @spec CHAT-API-030 CHAT-API-031
  it "queues revision-bound recovery for an authorized user" do
    sign_in user

    post recover_chat_session_chat_turn_path(chat_session, turn), params: { revision: turn.lock_version }

    expect(response).to redirect_to(chat_session_path(chat_session))
    expect(turn.reload.status).to eq("pending")
  end
end
