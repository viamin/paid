# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    initiating_message { association :chat_message, chat_session: chat_session }
    status { "pending" }
    last_activity_at { Time.current }
    recovery_attempts { 0 }
    metadata { {} }
  end
end
