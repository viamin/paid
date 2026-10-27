# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    user_message { association :chat_message, chat_session:, role: "user" }
    stream_message_id { SecureRandom.uuid }
    status { "pending" }
    activity_at { Time.current }
    recovery_attempts { 0 }
    metadata { {} }
  end
end
