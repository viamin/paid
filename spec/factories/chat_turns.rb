# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    stream_message_id { SecureRandom.uuid }
    state { "pending" }
    last_activity_at { Time.current }
  end
end
