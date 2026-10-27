# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    association :chat_session
    stream_message_id { SecureRandom.uuid }
    status { "streaming" }
    last_activity_at { Time.current }
  end
end
