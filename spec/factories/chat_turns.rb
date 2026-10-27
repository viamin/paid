# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    actor { association :user, account: chat_session.account }
    user_message { association :chat_message, chat_session: chat_session, role: "user" }
    status { "pending" }
    last_activity_at { Time.current }
    recovery_attempts { 0 }
    metadata { {} }
  end
end
