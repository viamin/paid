# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    actor { chat_session.created_by || association(:user, account: chat_session.account) }
    user_message { association(:chat_message, chat_session:, role: "user") }
    status { "pending" }
    last_activity_at { Time.current }
  end
end
